/** 読み取ってよい場所の 1 件。ここに載らないパスは存在しても読まない。 */
export type Source =
  | { readonly kind: "file" | "dir"; readonly root: "home" | "appSupport"; readonly path: string }
  | { readonly kind: "cli"; readonly command: string[] };

export type AgentId = "claude" | "cursor" | "codex" | "gemini";
export type KindId = "mcp" | "skill" | "subagent" | "plugin";
export type ScopeId = "user" | "project";

export const AGENT_IDS: readonly AgentId[] = ["claude", "cursor", "codex", "gemini"];

export const displayName = (agent: AgentId): string =>
  ({ claude: "Claude Code", cursor: "Cursor", codex: "Codex", gemini: "Gemini CLI" })[agent];

/** Cursor には CLI が無い（`cursor-agent` は存在しない）。異常ではないので未検出と扱わない。 */
export const cliName = (agent: AgentId): string | null =>
  ({ claude: "claude", cursor: null, codex: "codex", gemini: "gemini" })[agent];

/** ホーム相対の設定ディレクトリ。存在確認にだけ使い、走査はしない。 */
export const configDir = (agent: AgentId): string =>
  ({ claude: ".claude", cursor: ".cursor", codex: ".codex", gemini: ".gemini" })[agent];

/** 「非対応」と「未検出」を混ぜない。同じ表示にすると入れれば使えると誤解される。 */
export function supports(agent: AgentId, kind: KindId): boolean {
  switch (agent) {
    case "claude":
    case "cursor":
      return true;
    case "codex":
      return kind !== "subagent"; // Subagent の概念が無い
    case "gemini":
      return kind === "mcp";
  }
}

/** このエージェントが実際に走査するスキルルート（ホーム相対）。Cursor は他社のも読む。 */
export function skillRoots(agent: AgentId): string[] {
  switch (agent) {
    case "claude":
      return [".claude/skills"];
    case "cursor":
      return [".cursor/skills", ".cursor/skills-cursor", ".cursor/cloud-skills",
              ".claude/skills", ".codex/skills", ".grok/skills", ".agents/skills"];
    case "codex":
      return [".codex/skills", ".codex/skills/.system", ".agents/skills"];
    case "gemini":
      return [];
  }
}

/** Subagent は共有ルートの慣習が無く、各エージェントが自分のディレクトリしか読まない。 */
export function subagentRoots(agent: AgentId): string[] {
  switch (agent) {
    case "claude": return [".claude/agents"];
    case "cursor": return [".cursor/agents"];
    case "codex":
    case "gemini": return [];
  }
}

/**
 * エージェントに最初から入っているスキルのルート。ユーザーが入れたものと混ぜない —
 * 混ぜると自分が入れたものが同梱スキルに埋もれ、削除の対象にもなってしまう。
 */
export const BUNDLED_SKILL_ROOTS: ReadonlySet<string> = new Set([
  ".cursor/skills-cursor", ".cursor/cloud-skills", ".codex/skills/.system",
]);

/**
 * MCP の読み取り元。設定ファイルの直読みを優先し、Codex だけ設定が `config.toml` なので
 * CLI の JSON を使う。`Source` の MCP 部分はここから導出する（二重に書かない）。
 */
export function mcpSource(agent: AgentId): Source | null {
  switch (agent) {
    case "claude": return { kind: "file", root: "home", path: ".claude.json" }; // key: mcpServers
    case "cursor": return { kind: "file", root: "home", path: ".cursor/mcp.json" };
    case "gemini": return { kind: "file", root: "home", path: ".gemini/settings.json" };
    case "codex":  return { kind: "cli", command: ["codex", "mcp", "list", "--json"] };
  }
}

/** プラグインの読み取り元。書き込みは各 CLI に委譲する。 */
export function pluginSources(agent: AgentId): Source[] {
  switch (agent) {
    case "claude":
      return [{ kind: "file", root: "home", path: ".claude/plugins/installed_plugins.json" },
              { kind: "file", root: "home", path: ".claude/plugins/known_marketplaces.json" },
              { kind: "cli", command: ["claude", "plugin", "list", "--json"] }];
    case "codex":
      return [{ kind: "cli", command: ["codex", "plugin", "list", "--json"] }];
    case "cursor":
    case "gemini":
      return []; // Cursor の ~/.cursor/plugins は読み取り経路が未実測。推測で埋めない
  }
}

/**
 * プロセス一覧からエージェントを見分ける手掛かり。実行ファイル名で当てられないものだけ。
 * 部分一致なので、そのエージェントのプロセスにしか現れない語だけを載せる。
 */
export function processMarkers(agent: AgentId): string[] {
  return agent === "cursor" ? ["Cursor.app/", "Cursor Helper"] : [];
}
