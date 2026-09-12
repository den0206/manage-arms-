import { spawn } from "node:child_process";
import { AgentToolError } from "../core/errors";
import { redact } from "./mcpServer";

/** 出力とタイムアウトの上限。拡張のメモリにも CLI の待ち時間にも効く。 */
export const OUTPUT_LIMIT = 2 * 1024 * 1024;
export const TIMEOUT_MS = 180_000;

/**
 * `cmd.exe` に解釈される文字。Windows は `.cmd` / `.bat` を起動するために
 * `shell: true` が要るが、Node はこのとき引数を一切クォートしない。
 * MCP の起動コマンドと引数は貼り付けられた JSON 由来なので、ここを素通しにすると
 * `{"args":["x & calc"]}` がそのまま実行される。呼び出し側ごとではなく実行の入口で塞ぐ。
 */
const SHELL_SYNTAX = /[&|<>^"%!]|\r|\n/;

/** 純粋関数にして全 OS でテストする（実行時に効くのは win32 だけ）。 */
export const hasShellSyntax = (command: string[]): boolean =>
  command.some(part => SHELL_SYNTAX.test(part));

function assertNoShellSyntax(command: string[]): void {
  if (hasShellSyntax(command)) {
    throw new AgentToolError("INVALID_NAME",
      "this command cannot be run on Windows because it contains shell syntax");
  }
}

/**
 * 外部コマンドを 1 回実行して標準出力を返す。
 * 走査から見た唯一のプロセス依存で、`Run` として注入する。
 */
export function run(command: string[],
                    options: { path?: string; cwd?: string; envOverride?: Record<string, string> } = {}):
  Promise<string> {
  const [file, ...args] = command;
  if (file === undefined) return Promise.resolve("");
  if (process.platform === "win32") assertNoShellSyntax(command);

  return new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      cwd: options.cwd,
      // PATH を明示できるようにする。GUI から起動されたプロセスの PATH は
      // ログインシェルのものと違い、Homebrew 配下の CLI が 1 つも見つからない。
      // 互換検査は資格情報を引き継がせないため、環境そのものを差し替える。
      env: options.envOverride
        ?? (options.path === undefined ? process.env : { ...process.env, PATH: options.path }),
      stdio: ["ignore", "pipe", "pipe"],
      // Windows では .cmd / .bat も実行対象になるため shell 解決を許す。
      shell: process.platform === "win32",
    });

    let stdout = "";
    let stderr = "";
    let exceeded = false;
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 200).unref();
    }, TIMEOUT_MS);
    timer.unref();

    const append = (current: string, chunk: Buffer): string => {
      if (Buffer.byteLength(current) + chunk.byteLength > OUTPUT_LIMIT) {
        exceeded = true;
        child.kill("SIGKILL");
        return current;
      }
      return current + chunk.toString();
    };
    child.stdout.on("data", chunk => { stdout = append(stdout, chunk as Buffer); });
    child.stderr.on("data", chunk => { stderr = append(stderr, chunk as Buffer); });

    child.on("error", error => {
      clearTimeout(timer);
      reject(new AgentToolError("OPERATION_FAILED", `${file} could not be started: ${error.message}`));
    });
    child.on("close", exitCode => {
      clearTimeout(timer);
      if (exceeded) {
        return reject(new AgentToolError("OPERATION_FAILED", `${file} produced more than 2 MB of output`));
      }
      if (exitCode === 0) return resolve(stdout);
      // 引数にシークレットが載ることがあるので、必ずマスクしてから見せる。
      const shown = [file, ...redact(args)].slice(0, 3).join(" ");
      reject(new AgentToolError("OPERATION_FAILED",
        `\`${shown}\` exited with ${exitCode}: ${stderr.slice(-1024)}`));
    });
  });
}
