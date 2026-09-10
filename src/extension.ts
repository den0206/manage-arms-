import * as vscode from "vscode";
import { execFile } from "node:child_process";
import * as agentTool from "./agentTool";
import { AgentId, KindId } from "./agent";
import { AgentToolError } from "./errors";
import { hasLegacyData, legacyPath } from "./migration";
import { mcpServers } from "./pasteInput";
import { DashboardItem, DashboardProvider } from "./dashboard";

/** 旧 Mac App は macOS 専用。他の OS では検知そのものを行わない。 */
function isMacAppRunning(): Promise<boolean> {
  if (process.platform !== "darwin") return Promise.resolve(false);
  return new Promise(resolve => execFile("pgrep", ["-x", "ManageArms"], error => resolve(!error)));
}

type ToolNode = { tool: DashboardItem; scope: DashboardItem["scope"]; agent?: string };

const selectorOf = (node: ToolNode): agentTool.Selector => ({
  name: node.tool.name, kind: node.tool.kind as KindId, scope: node.scope,
  agent: node.agent as AgentId, sourcePath: node.tool.sourcePath,
});

const message = (error: unknown): string =>
  error instanceof AgentToolError || error instanceof Error ? error.message : String(error);

export function activate(context: vscode.ExtensionContext): void {
  const storagePath = context.globalStorageUri.fsPath;
  const dashboard = new DashboardProvider(storagePath);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("agent-tool.inventory", dashboard), dashboard);

  /** 書き込みの共通ガード。未信頼・Remote・旧 Mac App 起動中は操作しない。 */
  async function canWrite(): Promise<boolean> {
    if (!vscode.workspace.isTrusted) {
      void vscode.window.showWarningMessage(vscode.l10n.t("Agent Tool: trust this workspace before changing tools."));
      return false;
    }
    if (vscode.env.remoteName) {
      void vscode.window.showWarningMessage(vscode.l10n.t("Agent Tool: tool changes are available only in the local window."));
      return false;
    }
    if (await isMacAppRunning()) {
      void vscode.window.showWarningMessage(vscode.l10n.t("Agent Tool: ManageArms is running. Quit it before making changes."));
      return false;
    }
    return true;
  }

  /**
   * 成否は戻り値の有無ではなく `ok` で表す。`void` を返す操作（削除・追加）は
   * 成功しても `undefined` になるので、有無で判定すると一覧の再読み込みが走らない。
   */
  type Outcome<T> = { ok: true; value: T } | { ok: false };

  async function withProgress<T>(title: string, body: () => Promise<T>): Promise<Outcome<T>> {
    try {
      return {
        ok: true,
        value: await vscode.window.withProgress(
          { location: vscode.ProgressLocation.Notification, title }, body),
      };
    } catch (error) {
      void vscode.window.showWarningMessage(`Agent Tool: ${message(error)}`);
      return { ok: false };
    }
  }

  const command = (name: string, body: (...args: never[]) => unknown): void => {
    context.subscriptions.push(vscode.commands.registerCommand(name, body));
  };

  command("agent-tool.toggleTool", async (node: ToolNode) => {
    if (!node?.tool || !node.agent || !await canWrite()) return;
    const selector = selectorOf(node);
    const result = await withProgress(vscode.l10n.t("Agent Tool: Updating tool"),
      () => agentTool.toggle({ storagePath, selector }));
    if (result.ok) void dashboard.refresh(true);
  });

  command("agent-tool.addSkill", async (providedUrl?: string) => {
    if (!await canWrite()) return;
    const url = providedUrl ?? await vscode.window.showInputBox({
      prompt: vscode.l10n.t("Public GitHub Skill URL"),
      placeHolder: "https://github.com/owner/repository",
      ignoreFocusOut: true,
    });
    if (!url) return;
    const result = await withProgress(vscode.l10n.t("Agent Tool: Adding Skill"),
      () => agentTool.add({ storagePath, url, kind: "skill", scope: "user" }));
    if (result.ok) void dashboard.refresh(true);
  });

  command("agent-tool.addMcp", async () => {
    if (!await canWrite()) return;
    const name = await vscode.window.showInputBox({
      prompt: vscode.l10n.t("MCP server name"), ignoreFocusOut: true,
    });
    if (!name) return;
    const definition = await vscode.window.showInputBox({
      prompt: vscode.l10n.t("MCP server JSON, HTTP URL, or launch command"),
      placeHolder: "{\"command\":\"npx\",\"args\":[\"-y\",\"server\"]}",
      ignoreFocusOut: true,
    });
    if (!definition) return;
    const result = await withProgress(vscode.l10n.t("Agent Tool: Adding MCP server"), async () => {
      for (const server of mcpServers(definition, name)) {
        await agentTool.mcpAdd({ storagePath, agent: "cursor", server });
      }
    });
    if (result.ok) void dashboard.refresh(true);
  });

  command("agent-tool.installPreview", async (input: {
    url?: string; kind?: string; name?: string; selector?: string;
  }) => {
    if (!input?.url || !input.kind || !input.name || !await canWrite()) return;
    let agent: AgentId | undefined;
    if (input.kind === "plugin") {
      const pluginAgents = { "Claude Code": "claude", Codex: "codex" } as const;
      const picked = await vscode.window.showQuickPick(Object.keys(pluginAgents),
        { placeHolder: vscode.l10n.t("Choose an AI agent") });
      if (!picked) return;
      agent = pluginAgents[picked as keyof typeof pluginAgents];
      const commands = agentTool.pluginAddCommands(agent, input.selector ?? input.name, input.url);
      const choice = await vscode.window.showWarningMessage(
        vscode.l10n.t("Install {0}?", input.selector ?? input.name),
        { modal: true, detail: commands.map(argv => argv.join(" ")).join("\n") }, vscode.l10n.t("Install"));
      if (choice !== vscode.l10n.t("Install")) return;
    }
    const result = await withProgress(vscode.l10n.t("Agent Tool: Installing Tool"), () =>
      input.kind === "plugin"
        ? agentTool.pluginAdd({ storagePath, agent: agent!, name: input.selector ?? input.name!, url: input.url })
        : agentTool.add({
          storagePath, url: input.url!, scope: "user",
          kind: input.kind as "skill" | "subagent" | "plugin", name: input.name,
        }));
    if (result.ok) void dashboard.refresh(true);
  });

  command("agent-tool.removeTool", async (node: ToolNode) => {
    if (!node?.tool || !node.agent || !await canWrite()) return;
    // ゴミ箱には送らないので、取り消せないことを明示して確認を取る（設計決定 D-5）。
    const pluginCommand = node.tool.kind === "plugin"
      && (node.agent === "claude" || node.agent === "codex")
      ? agentTool.pluginRemoveCommand(node.agent, node.tool.name, node.tool.pluginScope ?? "user").join(" ")
      : undefined;
    const choice = await vscode.window.showWarningMessage(
      vscode.l10n.t("Remove {0}? This cannot be undone.", node.tool.name),
      { modal: true, detail: pluginCommand ?? node.tool.sourcePath }, vscode.l10n.t("Remove"));
    if (!choice) return;

    const selector = selectorOf(node);
    // 種別ごとに宛先が違う。Skill / Subagent だけがこちらの管理ストアの実体で、
    // MCP は設定ファイルか CLI、Plugin はエージェントの CLI が持っている。
    const result = await withProgress(vscode.l10n.t("Agent Tool: Removing tool"), () => {
      switch (node.tool.kind) {
        case "mcp":
          // `mcpScope` は一覧が読んだ登録先そのもの。`scope` に潰すと
          // プロジェクトのサーバーを消したつもりで user のサーバーが消える。
          return agentTool.mcpRemove({
            storagePath, agent: selector.agent, name: selector.name,
            scope: node.tool.mcpScope ?? "user",
          });
        case "plugin":
          return agentTool.pluginRemove({
            storagePath, agent: selector.agent, name: selector.name,
            scope: node.tool.pluginScope ?? "user",
            bundled: node.tool.origin === "bundled",
          });
        default:
          return agentTool.remove({ storagePath, selector });
      }
    });
    if (result.ok) void dashboard.refresh(true);
  });

  command("agent-tool.previewUpdate", async (node: ToolNode) => {
    if (!node?.tool || !node.agent) return;
    const selector = selectorOf(node);
    const previewed = await withProgress(vscode.l10n.t("Agent Tool: Preparing diff"),
      () => agentTool.updatePreview({ storagePath, selector }));
    if (!previewed.ok) return;
    const diff = previewed.value;
    if (diff.files.length === 0) {
      void vscode.window.showInformationMessage(vscode.l10n.t("Agent Tool: {0} is up to date.", node.tool.name));
      return;
    }
    // 本文は Diff Editor に渡すあいだだけ持ち、Editor を閉じたら破棄する。
    const first = diff.files[0];
    const before = await vscode.workspace.openTextDocument({ content: first.before });
    const after = await vscode.workspace.openTextDocument({ content: first.after });
    await vscode.commands.executeCommand("vscode.diff", before.uri, after.uri,
      `${node.tool.name}: ${diff.currentSha?.slice(0, 7) ?? "-"} → ${diff.latestSha.slice(0, 7)}`);
  });

  command("agent-tool.applyUpdate", async (node: ToolNode) => {
    if (!node?.tool || !node.agent || !await canWrite()) return;
    const selector = selectorOf(node);
    const result = await withProgress(vscode.l10n.t("Agent Tool: Applying update"),
      () => agentTool.updateApply({ storagePath, selector }));
    if (result.ok) void dashboard.refresh(true);
  });

  command("agent-tool.refreshInventory", () => void dashboard.refresh(true));

  command("agent-tool.openToolActions", async (item: DashboardItem) => {
    const agent = item.agents.length === 1
      ? item.agents[0]
      : await vscode.window.showQuickPick(item.agents, { placeHolder: vscode.l10n.t("Choose an agent") });
    if (!agent) return;
    const node: ToolNode = { tool: item, scope: item.scope, agent };
    // 実体を管理できない対象には有効化・更新を出さない。
    // 削除だけは宛先が別にある — MCP は設定ファイルか CLI、Plugin はエージェントの CLI。
    // 同梱物は消してもエージェントの更新で戻るので、そもそも出さない。
    const manageable = agentTool.isManageable(selectorOf(node));
    const removable = manageable
      || (item.origin !== "bundled"
        && (item.kind === "mcp"
          || (item.kind === "plugin" && (agent === "claude" || agent === "codex"))));
    const actions = [
      ...(manageable ? [{ label: vscode.l10n.t("Enable or disable"), value: "agent-tool.toggleTool" }] : []),
      ...(manageable && item.hasUpdate
        ? [{ label: vscode.l10n.t("Preview update"), value: "agent-tool.previewUpdate" },
           { label: vscode.l10n.t("Apply update"), value: "agent-tool.applyUpdate" }] : []),
      ...(removable ? [{ label: vscode.l10n.t("Remove"), value: "agent-tool.removeTool" }] : []),
    ];
    if (actions.length === 0) {
      void vscode.window.showInformationMessage(
        vscode.l10n.t("Agent Tool: {0} is managed outside Agent Tool.", item.name));
      return;
    }
    const choice = await vscode.window.showQuickPick(actions, { placeHolder: item.name });
    if (choice) await vscode.commands.executeCommand(choice.value, node);
  });

  command("agent-tool.migrateFromManageArms", () => void offerMigration(true));

  async function offerMigration(manual: boolean): Promise<void> {
    const source = legacyPath();
    if (source === null || !hasLegacyData()) {
      if (manual) {
        void vscode.window.showInformationMessage(vscode.l10n.t("Agent Tool: no ManageArms data was found."));
      }
      return;
    }
    if (!manual && (context.globalState.get("migrationDone") || context.globalState.get("migrationDeclined"))) {
      return;
    }
    const choice = await vscode.window.showInformationMessage(
      vscode.l10n.t("Migrate ManageArms data to Agent Tool?"),
      vscode.l10n.t("Migrate"), vscode.l10n.t("Later"), vscode.l10n.t("Don't migrate"));
    if (choice === vscode.l10n.t("Don't migrate")) {
      await context.globalState.update("migrationDeclined", true);
      return;
    }
    if (choice !== vscode.l10n.t("Migrate")) return;
    const result = await withProgress(vscode.l10n.t("Agent Tool: Migrating ManageArms data"),
      () => agentTool.migrate({ storagePath, sourcePath: source }));
    if (!result.ok) return;
    await context.globalState.update("migrationDone", true);
    void dashboard.refresh(true);
  }

  void offerMigration(false);
}

export function deactivate(): void {}
