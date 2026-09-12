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
