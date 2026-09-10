import { AgentToolError } from "./errors";
import { GitHubSource, parseUrl } from "./github";
import { MCPServer, parse as parseServer, parseAll } from "./mcpServer";

/** 入力欄は 1 つだけ。貼り付けられた文字列を見て分岐する。 */
export type PasteInput =
  /** 公式サイトが載せている JSON をそのままコピペできる。最頻の導線。 */
  | { readonly kind: "mcpJson"; readonly text: string }
  | { readonly kind: "github"; readonly source: GitHubSource }
  /** `npx -y foo-mcp` などのコマンド行。 */
  | { readonly kind: "command"; readonly command: string[] }
  | { readonly kind: "unrecognized" };

export function classify(raw: string): PasteInput {
  const text = raw.trim();
  if (text === "") return { kind: "unrecognized" };
  if (text.startsWith("{") && text.includes("mcpServers")) return { kind: "mcpJson", text };
  const source = parseUrl(text);
  if (source !== null) return { kind: "github", source };
  const command = parseCommand(text);
  return command === null ? { kind: "unrecognized" } : { kind: "command", command };
}

/** 実行ファイルらしき先頭トークンを持つ 1 行だけをコマンドとして受ける。 */
const RUNNERS: ReadonlySet<string> = new Set([
  "npx", "uvx", "uv", "bunx", "pnpm", "node", "python", "python3", "deno",
]);

export function parseCommand(text: string): string[] | null {
  if (text.includes("\n")) return null;
  const words = commandWords(text);
  const head = words?.[0];
  if (words === null || head === undefined) return null;
  if (!RUNNERS.has(head) && !head.startsWith("/") && !head.startsWith("./")) return null;
  return words;
}

/** 引用符を解くだけで、シェルの式は評価しない。式が混ざっていたら受け取らない。 */
export function commandWords(text: string): string[] | null {
  const words: string[] = [];
  let word = "";
  let quote: string | null = null;
  let escaped = false;
  let started = false;

  for (const character of text) {
    if (escaped) { word += character; escaped = false; started = true; continue; }
    if (character === "\\" && quote !== "'") { escaped = true; started = true; continue; }
    if (quote !== null) {
      if (character === quote) quote = null;
      else word += character;
      continue;
    }
    if (character === "'" || character === "\"") { quote = character; started = true; continue; }
    if ("|;&<>`$\n\r".includes(character)) return null;
    if (/\s/.test(character)) {
      if (started) { words.push(word); word = ""; started = false; }
      continue;
    }
    word += character;
    started = true;
  }
  if (quote !== null || escaped) return null;
  if (started) words.push(word);
  return words;
}

/**
 * 貼り付けられた 1 つの入力から MCP サーバー定義を作る。
 * JSON・HTTP の URL・引用符付きの起動コマンドの 3 形式だけを受ける。
 */
export function mcpServers(raw: string, name: string): MCPServer[] {
  const text = raw.trim();
  if (text.startsWith("{")) {
    let object: unknown;
    try {
      object = JSON.parse(text);
    } catch {
      throw new AgentToolError("OPERATION_FAILED", "the MCP settings must be a JSON object");
    }
    if (typeof object !== "object" || object === null || Array.isArray(object)) {
      throw new AgentToolError("OPERATION_FAILED", "the MCP settings must be a JSON object");
    }
    const record = object as Record<string, unknown>;
    if (record.command !== undefined || record.url !== undefined) {
      const server = parseServer(name, record);
      if (server === null) {
        throw new AgentToolError("OPERATION_FAILED", "the MCP definition could not be read");
      }
      return [server];
    }
    return parseAll(record);
  }

  try {
    const url = new URL(text);
    if (url.protocol === "http:" || url.protocol === "https:") {
      return [{ name, transport: { type: "http", url: text, headers: {} }, isProtected: false, enabled: true }];
    }
  } catch { /* URL でなければコマンドとして読む */ }

  const words = parseCommand(text);
  if (words === null) {
    throw new AgentToolError("OPERATION_FAILED",
      "enter MCP settings JSON, an HTTP URL, or a quoted launch command; shell expressions are not accepted");
  }
  return [{
    name,
    transport: { type: "stdio", command: words[0], args: words.slice(1), env: {} },
    isProtected: false,
    enabled: true,
  }];
}
