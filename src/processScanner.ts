import { basename } from "node:path";
import { AgentId, AGENT_IDS, cliName, processMarkers } from "./agent";
import { Run } from "./env";
import { MCPServer } from "./mcpServer";

/** プロセス一覧の 1 行。`elapsed` は表示にしか使わないので秒へ直さない。 */
export type ProcessRow = {
  readonly pid: number;
  readonly ppid: number;
  readonly elapsed: string;
  readonly command: string;
};

export type RunningMCP = {
  /** 親を辿って特定できたエージェント。辿り着けなければ null。 */
  readonly owner: AgentId | null;
  readonly elapsed: string;
  readonly pid: number;
};

/**
 * 全プロセスを 1 回だけ取る。OS ごとにコマンドは違うが、
 * 「pid / ppid / 経過 / コマンド行」の 4 列に揃えてから先は同じ処理にする。
 */
export async function snapshot(run: Run): Promise<ProcessRow[]> {
  if (process.platform === "win32") {
    // tasklist はコマンド行を持たないので、MCP の判別に使えない。
    const script = "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,"
      + "CreationDate,CommandLine | ConvertTo-Json -Compress";
    const output = await run(["powershell", "-NoProfile", "-Command", script]).catch(() => "");
    return parseWindows(output);
  }
  const output = await run(["ps", "-eo", "pid,ppid,etime,command"]).catch(() => "");
  return parsePs(output);
}

/** `  87139 87070       18:58 Cursor Helper: mcp-process` */
export function parsePs(output: string): ProcessRow[] {
  return output.split("\n").flatMap(line => {
    // コマンドは空白を含むので、先頭 3 列だけ切り出して残りを丸ごと使う。
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (match === null) return [];      // ヘッダ行はここで落ちる
    return [{ pid: Number(match[1]), ppid: Number(match[2]), elapsed: match[3], command: match[4] }];
  });
}

export function parseWindows(output: string): ProcessRow[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(output);
  } catch {
    return [];
  }
  const list = Array.isArray(parsed) ? parsed : [parsed];
  return list.flatMap(raw => {
    if (typeof raw !== "object" || raw === null) return [];
    const item = raw as Record<string, unknown>;
    if (typeof item.ProcessId !== "number" || typeof item.CommandLine !== "string") return [];
    return [{
      pid: item.ProcessId,
      ppid: typeof item.ParentProcessId === "number" ? item.ParentProcessId : 0,
      elapsed: typeof item.CreationDate === "string" ? item.CreationDate : "",
      command: item.CommandLine,
    }];
  });
}

/** パッケージ実行系はコマンド行に現れても対象を絞らない。 */
const GENERIC: ReadonlySet<string> = new Set([
  "npx", "npm", "exec", "node", "uvx", "uv", "run", "python", "python3",
  "deno", "bunx", "docker", "pipx", "-y", "--yes", "latest",
]);

/** `chrome-devtools-mcp@latest` → `chrome-devtools-mcp`。スコープ付きの先頭 `@` は残す。 */
export function stripVersion(token: string): string {
  const at = token.lastIndexOf("@");
  return at > 0 ? token.slice(0, at) : token;
}

/**
 * プロセスを一意に指す語。`npx -y chrome-devtools-mcp@latest` なら
 * `chrome-devtools-mcp` が拾える。`npx` や `-y` のような共通語では照合しない —
 * 無関係なプロセスに当たる。3 文字以下も切る（`uv` が全部に一致する）。
 */
export function signatures(server: MCPServer): string[] {
  const tokens: string[] = [];
  if (server.transport.type === "stdio") {
    for (const token of server.transport.args) {
      if (!token.startsWith("-")) tokens.push(stripVersion(token));
    }
    tokens.push(stripVersion(basename(server.transport.command)));
  } else {
    tokens.push(server.transport.url);
  }
  // サーバー名そのものは最後の手掛かり。設定に固有の語が無いことがある。
  tokens.push(server.name);
  return tokens.filter(token => token.length > 3 && !GENERIC.has(token));
}

/**
 * 登録済みの設定から探す。UI が答えたい問いは「この登録済みサーバーは動いているか」で、
 * 「動いている MCP を全部挙げよ」ではない。
 */
export function running(servers: MCPServer[], rows: ProcessRow[]): Map<string, RunningMCP> {
  const result = new Map<string, RunningMCP>();
  for (const server of servers) {
    if (!server.enabled) continue;
    const tokens = signatures(server);
    if (tokens.length === 0) continue;
    const matched = rows.filter(row => tokens.some(token => row.command.includes(token)));
    if (matched.length === 0) continue;

    // 同じサーバーが npm exec → 本体 → watchdog と数珠つなぎになる（実測）。
    // 一致した集合の中で親を持たないものが起点で、稼働時間もそれが正しい。
    const pids = new Set(matched.map(row => row.pid));
    const root = matched.find(row => !pids.has(row.ppid)) ?? matched[0];
    result.set(server.name, { owner: owner(root, rows), elapsed: root.elapsed, pid: root.pid });
  }
  return result;
}

/**
 * 親を辿ってエージェントに行き着くか見る。実測:
 * `chrome-devtools-mcp` → `npm exec` → `Cursor Helper: mcp-process` → `Cursor.app`
 */
export function owner(row: ProcessRow, rows: ProcessRow[]): AgentId | null {
  const byPid = new Map(rows.map(item => [item.pid, item]));
  let current: ProcessRow | undefined = row;
  for (let depth = 0; current !== undefined && depth < 24; depth++) {  // 循環しても抜ける
    const agent = agentOfCommand(current.command);
    if (agent !== null) return agent;
    if (current.ppid <= 1) return null;
    current = byPid.get(current.ppid);
  }
  return null;
}

/**
 * 実行ファイル名を先に見る。Codex は Cursor の拡張の中に入っていることがあり、
 * パスに `cursor` が含まれるからと先に Cursor と判定すると取り違える。
 */
export function agentOfCommand(command: string): AgentId | null {
  const executable = command.split(" ")[0] ?? command;
  const name = basename(executable).replace(/\.(exe|cmd|bat)$/i, "");
  const byCli = AGENT_IDS.find(agent => cliName(agent) === name);
  if (byCli !== undefined) return byCli;
  return AGENT_IDS.find(agent => processMarkers(agent).some(marker => command.includes(marker))) ?? null;
}

/** View 表示中の 3 秒ポーリングから呼ぶ。key は "agent:serverName"。 */
export async function mcpStatus(servers: Partial<Record<AgentId, MCPServer[]>>, run: Run):
  Promise<Record<string, boolean>> {
  const rows = await snapshot(run);
  const status: Record<string, boolean> = {};
  for (const agent of AGENT_IDS) {
    const live = running(servers[agent] ?? [], rows);
    for (const server of servers[agent] ?? []) {
      status[`${agent}:${server.name}`] = live.has(server.name);
    }
  }
  return status;
}
