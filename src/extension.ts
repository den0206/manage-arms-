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

type Scope = "user" | "project";
type Origin = "managed" | "user" | "bundled";
type InventoryItem = { name: string; kind: "skill" | "subagent" | "mcp" | "plugin"; scope: Scope; agents: string[]; enabled: boolean; origin: Origin; sourcePath?: string; repoUrl?: string; hasUpdate: boolean };
type UndoPayload = { originalPath: string; trashedPath: string; registryEntry: object };
type NodeType = "scope" | "agent" | "kind" | "origin" | "tool" | "empty";
const agentLabels: Record<string, string> = { claude: "Claude Code", cursor: "Cursor", codex: "Codex", gemini: "Gemini CLI" };
const kindLabels: Record<InventoryItem["kind"], string> = { skill: "Skills", subagent: "Subagents", mcp: "MCP Servers", plugin: "Plugins" };
const originLabels: Record<Origin, string> = { managed: "Your tools", user: "Your tools", bundled: "Bundled" };

class InventoryNode extends vscode.TreeItem {
  constructor(readonly type: NodeType, readonly scope: Scope, readonly agent?: string, readonly kind?: InventoryItem["kind"], readonly origin?: Origin, readonly tool?: InventoryItem, readonly running?: boolean) {
    const label = tool?.name ?? (type === "scope" ? scope === "project" ? "Current Project" : "User Global" : type === "agent" ? agentLabels[agent ?? ""] ?? agent ?? "Unknown" : type === "kind" ? kindLabels[kind!] : type === "origin" ? originLabels[origin!] : "No tools found");
    super(label, type === "tool" || type === "empty" ? vscode.TreeItemCollapsibleState.None : vscode.TreeItemCollapsibleState.Collapsed);
    this.iconPath = this.icon();
    if (tool) {
      this.description = tool.kind === "mcp" ? running ? "Running" : "Stopped" : tool.hasUpdate ? "Update available" : undefined;
      this.contextValue = tool.origin === "managed" ? `agent-tool.managed.${tool.kind}` : `agent-tool.${tool.kind}`;
      this.tooltip = [tool.name, tool.sourcePath, tool.repoUrl].filter(Boolean).join("\n");
    }
  }
  private icon(): vscode.ThemeIcon {
    if (this.type === "scope") return new vscode.ThemeIcon(this.scope === "project" ? "folder" : "account");
    if (this.type === "agent") return new vscode.ThemeIcon("hubot");
    if (this.type === "kind") return new vscode.ThemeIcon({ skill: "book", subagent: "organization", mcp: "server", plugin: "extensions" }[this.kind!]);
    if (this.type === "origin") return new vscode.ThemeIcon(this.origin === "bundled" ? "package" : "person");
    if (this.type === "tool" && this.tool?.kind === "mcp") return new vscode.ThemeIcon(this.running ? "circle-filled" : "circle-outline");
    if (this.type === "tool") return new vscode.ThemeIcon(this.tool?.enabled ? "check" : "circle-slash");
    return new vscode.ThemeIcon("info");
  }
}

class InventoryProvider implements vscode.TreeDataProvider<InventoryNode>, vscode.Disposable {
  private readonly change = new vscode.EventEmitter<InventoryNode | undefined>();
  readonly onDidChangeTreeData = this.change.event;
  private snapshot?: { at: number; items: InventoryItem[] };
  private status = new Map<string, boolean>();
  private timer?: NodeJS.Timeout;
  constructor(private readonly storagePath: string) {}
  dispose(): void { this.change.dispose(); this.snapshot = undefined; if (this.timer) clearInterval(this.timer); }
  getTreeItem(node: InventoryNode): vscode.TreeItem { return node; }
  refresh(): void { this.snapshot = undefined; this.change.fire(undefined); }
  setVisible(visible: boolean): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    if (!visible) { this.snapshot = undefined; this.status.clear(); return; }
    void this.refreshMcpStatus();
    this.timer = setInterval(() => void this.refreshMcpStatus(), 3_000);
  }
  async getChildren(node?: InventoryNode): Promise<InventoryNode[]> {
    if (!node) return [new InventoryNode("scope", "project"), new InventoryNode("scope", "user")];
    const items = await this.items();
    if (node.type === "scope") {
      const agents = [...new Set(items.filter(item => item.scope === node.scope).flatMap(item => item.agents))];
      return agents.length ? agents.map(agent => new InventoryNode("agent", node.scope, agent)) : [new InventoryNode("empty", node.scope)];
    }
    if (node.type === "agent") {
      const kinds = [...new Set(items.filter(item => item.scope === node.scope && item.agents.includes(node.agent!)).map(item => item.kind))];
      return kinds.map(kind => new InventoryNode("kind", node.scope, node.agent, kind));
    }
    if (node.type === "kind") {
      const origins = [...new Set(items.filter(item => item.scope === node.scope && item.agents.includes(node.agent!) && item.kind === node.kind).map(item => item.origin === "bundled" ? "bundled" : "user" as Origin))];
      return origins.map(origin => new InventoryNode("origin", node.scope, node.agent, node.kind, origin));
    }
    if (node.type === "origin") return items.filter(item => item.scope === node.scope && item.agents.includes(node.agent!) && item.kind === node.kind && (node.origin === "bundled" ? item.origin === "bundled" : item.origin !== "bundled")).sort((a, b) => a.name.localeCompare(b.name)).map(item => new InventoryNode("tool", node.scope, node.agent, node.kind, node.origin, item, this.status.get(`${node.agent}:${item.name}`)));
    return [];
  }
  private async items(): Promise<InventoryItem[]> {
    if (this.snapshot && Date.now() - this.snapshot.at < 180_000) return this.snapshot.items;
    try {
      const result = await runCli("inventory", { storagePath: this.storagePath });
      const items = (result.data as { items?: InventoryItem[] } | undefined)?.items ?? [];
      this.snapshot = { at: Date.now(), items };
      return items;
    } catch { return []; }
  }
  private async refreshMcpStatus(): Promise<void> {
    try {
      const result = await runCli("mcp-status", { storagePath: this.storagePath });
      const servers = (result.data as { servers?: Array<{ agent: string; name: string; running: boolean }> } | undefined)?.servers ?? [];
      this.status = new Map(servers.map(server => [`${server.agent}:${server.name}`, server.running]));
      this.change.fire(undefined);
    } catch { /* Keep the previous in-memory status until the next visible poll. */ }
  }
}

export function activate(context: vscode.ExtensionContext): void {
  setCliPath(process.env.AGENT_TOOL_CORE_CLI ?? vscode.Uri.joinPath(context.extensionUri, "bin", "agent-tool-core").fsPath);
  const dashboard = new DashboardProvider(context.globalStorageUri.fsPath);
  let undo: UndoPayload | undefined;
  let undoTimer: NodeJS.Timeout | undefined;
  context.subscriptions.push(vscode.window.registerWebviewViewProvider("agent-tool.inventory", dashboard), dashboard);
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.toggleTool", async (node: InventoryNode) => {
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
    const scope = await vscode.window.showQuickPick(["User Global", "Current Project"], { placeHolder: "Choose where to install" });
    if (!scope) return;
    const agent = await vscode.window.showQuickPick(["Claude Code", "Cursor", "Codex", "Gemini CLI"], { placeHolder: "Choose an AI Agent" });
    if (!agent) return;
    if (scope === "Current Project") {
      void vscode.window.showWarningMessage("Agent Tool: Current Project installation is not available yet.");
      return;
    }
    if (await isMacAppRunning()) { void vscode.window.showWarningMessage("Agent Tool: ManageArms is running. Quit it before making changes."); return; }
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: "Agent Tool: Installing Tool" }, async () => {
      const result = input.kind === "plugin"
        ? await runCli("plugin-add", { storagePath: context.globalStorageUri.fsPath, agent: ({ "Claude Code": "claude", Cursor: "cursor", Codex: "codex", "Gemini CLI": "gemini" } as Record<string, string>)[agent], name: input.selector ?? input.name, url: input.url })
        : await runCli("add", { storagePath: context.globalStorageUri.fsPath, url: input.url, scope: "user", kind: input.kind });
      if (!result.ok) throw new Error(result.error?.message ?? "tool install failed");
    }).then(() => void dashboard.refresh(true), error => void vscode.window.showWarningMessage(`Agent Tool: ${error.message}`));
  }));
  context.subscriptions.push(vscode.commands.registerCommand("agent-tool.removeTool", async (node: InventoryNode) => {
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
    const node = { tool: item, scope: item.scope, agent } as unknown as InventoryNode;
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
