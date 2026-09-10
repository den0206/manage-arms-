import { spawn } from "node:child_process";
let cliPath = process.env.AGENT_TOOL_CORE_CLI ?? "agent-tool-core";
export type CliResponse = { ok: boolean; protocolVersion: string; data?: unknown; error?: { code: string; message: string } };
export function setCliPath(path: string): void { cliPath = path; }
export async function runCli(command: string, input: object = {}): Promise<CliResponse> {
  const stdout = await new Promise<string>((resolve, reject) => {
    const child = spawn(cliPath, [command], { stdio: ["pipe", "pipe", "pipe"] });
    let output = "";
    let stderr = "";
    var exceeded = false;
    const timeout = setTimeout(() => child.kill("SIGTERM"), 180_000);
    timeout.unref();
    const append = (current: string, chunk: Buffer): string => {
      const next = current + chunk.toString();
      if (Buffer.byteLength(next) > 2 * 1024 * 1024) { exceeded = true; child.kill("SIGKILL"); }
      return next;
    };
    child.stdout.on("data", chunk => { output = append(output, chunk); });
    child.stderr.on("data", chunk => { stderr = append(stderr, chunk); });
    child.on("error", reject);
    child.on("close", code => {
      clearTimeout(timeout);
      if (exceeded) reject(new Error("CLI output exceeded 2 MB"));
      else if (code === 0) resolve(output);
      else reject(new Error(`CLI exited ${code}: ${stderr.slice(-1024)}`));
    });
    child.stdin.end(JSON.stringify(input));
  });
  const result = JSON.parse(stdout) as CliResponse;
  if (result.protocolVersion !== "1") throw new Error("Agent Tool CLI protocol mismatch");
  return result;
}
