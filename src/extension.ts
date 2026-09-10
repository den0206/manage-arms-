import * as vscode from "vscode";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { runCli, setCliPath } from "./cli";
import { DashboardItem, DashboardProvider } from "./dashboard";

function isMacAppRunning(): Promise<boolean> {
  return new Promise(resolve => execFile("pgrep", ["-x", "ManageArms"], err => resolve(!err)));
}

type UndoPayload = { originalPath: string; trashedPath: string; registryEntry: object };
type ToolNode = { tool: DashboardItem; scope: DashboardItem["scope"]; agent?: string };


export function activate(context: vscode.ExtensionContext): void {
  setCliPath(process.env.AGENT_TOOL_CORE_CLI ?? vscode.Uri.joinPath(context.extensionUri, "bin", "agent-tool-core").fsPath);
  const dashboard = new DashboardProvider(context.globalStorageUri.fsPath);
  let undo: UndoPayload | undefined;
  let undoTimer: NodeJS.Timeout | undefined;
  context.subscriptions.push(vscode.window.registerWebviewViewProvider("agent-tool.inventory", dashboard), dashboard);
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.toggleTool", async (node: ToolNode) => {
    if (!node.tool || !node.agent || !vscode.workspace.isTrusted) {
      void vscode.window.showWarningMessage("Agent Tool: trust this workspace before changing tools.");
      return;
    }
    if (vscode.env.remoteName) {
      void vscode.window.showWarningMessage("Agent Tool: tool changes are available only in the local Cursor window.");
      return;
    }
    if (await isMacAppRunning()) {
      void vscode.window.showWarningMessage("Agent Tool: ManageArms is running. Quit it before making changes.");
      return;
    }
    const result = await runCli("toggle", {
      storagePath: context.globalStorageUri.fsPath,
      selector: { name: node.tool.name, kind: node.tool.kind, scope: node.scope, agent: node.agent, sourcePath: node.tool.sourcePath },
    });
    if (!result.ok) {
      void vscode.window.showWarningMessage(`Agent Tool: ${result.error?.message ?? "toggle failed"}`);
      return;
    }
    void dashboard.refresh(true);
  }));
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.addSkill", async (providedUrl?: string) => {
    if (!vscode.workspace.isTrusted || vscode.env.remoteName) {
      void vscode.window.showWarningMessage("Agent Tool: add tools only from a trusted local Cursor window.");
      return;
    }
    if (await isMacAppRunning()) {
      void vscode.window.showWarningMessage("Agent Tool: ManageArms is running. Quit it before making changes.");
      return;
    }
    const url = providedUrl ?? await vscode.window.showInputBox({ prompt: "Public GitHub Skill URL", placeHolder: "https://github.com/owner/repository", ignoreFocusOut: true });
    if (!url) return;
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: "Agent Tool: Adding Skill" }, async () => {
      const result = await runCli("add", { storagePath: context.globalStorageUri.fsPath, url, scope: "user", kind: "skill" });
      if (!result.ok) throw new Error(result.error?.message ?? "Skill add failed");
    }).then(() => void dashboard.refresh(true), error => void vscode.window.showWarningMessage(`Agent Tool: ${error.message}`));
  }));
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.addMcp", async () => {
    if (!vscode.workspace.isTrusted || vscode.env.remoteName) { void vscode.window.showWarningMessage("Agent Tool: add MCP servers only from a trusted local Cursor window."); return; }
    if (await isMacAppRunning()) { void vscode.window.showWarningMessage("Agent Tool: ManageArms is running. Quit it before making changes."); return; }
    const name = await vscode.window.showInputBox({ prompt: "MCP server name", ignoreFocusOut: true });
    const definition = await vscode.window.showInputBox({ prompt: "MCP server JSON", placeHolder: "{\"command\":\"npx\",\"args\":[\"-y\",\"server\"]}", ignoreFocusOut: true });
    if (!name || !definition) return;
    try {
      const server = { name, ...JSON.parse(definition) };
      const result = await runCli("mcp-add", { storagePath: context.globalStorageUri.fsPath, agent: "cursor", scope: "user", server });
      if (!result.ok) throw new Error(result.error?.message ?? "MCP add failed");
      void dashboard.refresh(true);
    } catch (error) { void vscode.window.showWarningMessage(`Agent Tool: ${error instanceof Error ? error.message : "invalid MCP definition"}`); }
  }));
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.addTool", async (input: { kind?: string; agent?: string; value?: string; extra?: string }) => {
    if (!vscode.workspace.isTrusted || vscode.env.remoteName) {
      void vscode.window.showWarningMessage("Agent Tool: add tools only from a trusted local Cursor window.");
      return;
    }
    if (await isMacAppRunning()) {
      void vscode.window.showWarningMessage("Agent Tool: ManageArms is running. Quit it before making changes.");
      return;
    }
    const kind = input.kind;
    const value = input.value?.trim();
    const agent = input.agent;
    if (!value || !agent || !["skill", "subagent", "mcp", "plugin"].includes(kind ?? "")) {
      void vscode.window.showWarningMessage("Agent Tool: complete the tool form.");
      return;
    }
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: "Agent Tool: Adding Tool" }, async () => {
      let result;
      if (kind === "mcp") {
        const server = { name: value, ...JSON.parse(input.extra ?? "") };
        result = await runCli("mcp-add", { storagePath: context.globalStorageUri.fsPath, agent, scope: "user", server });
      } else if (kind === "plugin") {
        result = await runCli("plugin-add", { storagePath: context.globalStorageUri.fsPath, agent, name: value, url: input.extra?.trim() || undefined });
      } else {
        result = await runCli("add", { storagePath: context.globalStorageUri.fsPath, url: value, scope: "user", kind });
      }
      if (!result.ok) throw new Error(result.error?.message ?? "tool add failed");
    }).then(() => void dashboard.refresh(true), error => void vscode.window.showWarningMessage(`Agent Tool: ${error.message}`));
  }));
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.installPreview", async (input: { url?: string; kind?: string; name?: string; selector?: string }) => {
    if (!vscode.workspace.isTrusted || vscode.env.remoteName || !input.url || !input.kind || !input.name) {
      void vscode.window.showWarningMessage("Agent Tool: install tools only from a trusted local Cursor window.");
      return;
    }
    const agentMap: Record<string, string> = { "Claude Code": "claude", Cursor: "cursor", Codex: "codex", "Gemini CLI": "gemini" };
    let agentId: string | undefined;
    if (input.kind === "plugin") {
      const picked = await vscode.window.showQuickPick(Object.keys(agentMap), { placeHolder: "Choose an AI Agent" });
      if (!picked) return;
      agentId = agentMap[picked];
    }
    if (await isMacAppRunning()) { void vscode.window.showWarningMessage("Agent Tool: ManageArms is running. Quit it before making changes."); return; }
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: "Agent Tool: Installing Tool" }, async () => {
      const result = input.kind === "plugin"
        ? await runCli("plugin-add", { storagePath: context.globalStorageUri.fsPath, agent: agentId, name: input.selector ?? input.name, url: input.url })
        : await runCli("add", { storagePath: context.globalStorageUri.fsPath, url: input.url, scope: "user", kind: input.kind });
      if (!result.ok) throw new Error(result.error?.message ?? "tool install failed");
    }).then(() => void dashboard.refresh(true), error => void vscode.window.showWarningMessage(`Agent Tool: ${error.message}`));
  }));
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.removeTool", async (node: ToolNode) => {
    if (!node.tool || !node.agent || !vscode.workspace.isTrusted || vscode.env.remoteName) {
      void vscode.window.showWarningMessage("Agent Tool: remove tools only from a trusted local Cursor window.");
      return;
    }
    if (await isMacAppRunning()) {
      void vscode.window.showWarningMessage("Agent Tool: ManageArms is running. Quit it before making changes.");
      return;
    }
    const choice = await vscode.window.showWarningMessage(`Remove ${node.tool.name}? It will be moved to Trash.`, { modal: true }, "Remove");
    if (choice !== "Remove") return;
    const result = node.tool.kind === "mcp"
      ? await runCli("mcp-remove", { storagePath: context.globalStorageUri.fsPath, agent: node.agent, name: node.tool.name, scope: node.scope })
      : await runCli("remove", { storagePath: context.globalStorageUri.fsPath, selector: { name: node.tool.name, kind: node.tool.kind, scope: node.scope, agent: node.agent, sourcePath: node.tool.sourcePath } });
    if (node.tool.kind === "mcp") {
      if (result.ok) void dashboard.refresh(true);
      else void vscode.window.showWarningMessage(`Agent Tool: ${result.error?.message ?? "remove failed"}`);
      return;
    }
    const payload = (result.data as { undo?: UndoPayload } | undefined)?.undo;
    if (!result.ok || !payload) {
      void vscode.window.showWarningMessage(`Agent Tool: ${result.error?.message ?? "remove failed"}`);
      return;
    }
    undo = payload;
    if (undoTimer) clearTimeout(undoTimer);
    undoTimer = setTimeout(() => { undo = undefined; }, 30_000);
    void dashboard.refresh(true);
    void vscode.window.showInformationMessage(`${node.tool.name} was moved to Trash.`, "Undo").then(async action => {
      if (action !== "Undo" || !undo) return;
      const restored = await runCli("rollback", { storagePath: context.globalStorageUri.fsPath, undo });
      undo = undefined;
      if (restored.ok) void dashboard.refresh(true);
      else void vscode.window.showWarningMessage(`Agent Tool: ${restored.error?.message ?? "rollback failed"}`);
    });
  }));
  context.subscriptions.push({ dispose: () => { if (undoTimer) clearTimeout(undoTimer); undo = undefined; } });
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.openToolActions", async (item: DashboardItem) => {
    const agent = item.agents.length === 1 ? item.agents[0] : await vscode.window.showQuickPick(item.agents, { placeHolder: "Choose an agent" });
    if (!agent) return;
    const choice = await vscode.window.showQuickPick(["Enable or disable", "Remove"], { placeHolder: item.name });
    const node: ToolNode = { tool: item, scope: item.scope, agent };
    if (choice === "Enable or disable") await vscode.commands.executeCommand("agent-tool.toggleTool", node);
    if (choice === "Remove") await vscode.commands.executeCommand("agent-tool.removeTool", node);
  }));
  void runCli("version").catch(() => undefined);
  const legacyPath = join(homedir(), "Library", "Application Support", "ManageArms");
  if (existsSync(join(legacyPath, "registry.json")) && !context.globalState.get("migrationDone") && !context.globalState.get("migrationDeclined")) {
    void vscode.window.showInformationMessage("Migrate ManageArms data to Agent Tool?", "Migrate", "Later", "Don't migrate").then(async choice => {
      if (choice === "Don't migrate") { await context.globalState.update("migrationDeclined", true); return; }
      if (choice !== "Migrate") return;
      await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: "Agent Tool: Migrating ManageArms data" }, async () => {
        const result = await runCli("migrate", { storagePath: context.globalStorageUri.fsPath, sourcePath: legacyPath });
        if (!result.ok) throw new Error(result.error?.message ?? "migration failed");
      }).then(async () => { await context.globalState.update("migrationDone", true); void dashboard.refresh(true); }, error => void vscode.window.showWarningMessage(`Agent Tool: ${error.message}`));
    });
  }
}
export function deactivate(): void {}
