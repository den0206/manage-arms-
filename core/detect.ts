import { catalog, components, GitHubSource, parseUrl } from "./github.js";

/**
 * ブラウザ拡張が扱う種別。MCP は URL に手がかりが無く、Plugin は CLI への登録が必要なので
 * どちらも扱わない（設計決定 D-12）。
 */
export type DetectKind = "skill" | "subagent";

/**
 * 「追加できる Tool」の候補。**URL だけでは種別は確定しない**ので、パス名で候補にして
 * `proofs` の実在を確かめてから利用者に見せる。
 */
export type ToolLead = {
  readonly url: string;
  readonly source: GitHubSource;
  readonly kind: DetectKind;
  readonly name: string;
  /**
   * `raw.githubusercontent.com` 上のパス。**どれか 1 つでも 200 なら本物**。
   * 空 = 確認不要（カタログページは配布物そのものが Skill だと分かっている）。
   */
  readonly proofs: readonly string[];
};

/** 実在確認に投げる URL。アーカイブは落とさない — 見ているだけで数 MB は取らない。 */
export const proofUrls = (lead: ToolLead, defaultBranch = "main"): string[] =>
  lead.proofs.map(path =>
    `https://raw.githubusercontent.com/${lead.source.repo}/`
    + `${lead.source.branch ?? defaultBranch}/${encodeURI(path)}`);

/** パス名だけで種別を当てる。ネットワークに触れない絞り込み。 */
export function kindOf(path: readonly string[]): DetectKind | null {
  const lower = new Set(path.map(part => part.toLowerCase()));
  // Plugin と MCP は扱わないので、見分けた上で落とす（Skill と誤認させない）。
  if (lower.has(".claude-plugin") || lower.has("plugins")) return null;
  if (lower.has("agents") || lower.has("subagents")) return "subagent";
  if (lower.has("skills")) return "skill";
  return null;
}

/**
 * 受ける形:
 *   https://skills.sh/owner/repo/skill      → Skill（カタログ。3 番目がスキル名）
 *   .../tree|blob/main/skills/foo           → Skill
 *   .../blob/main/agents/foo.md             → Subagent
 */
export function lead(raw: string): ToolLead | null {
  const url = raw.trim();

  // カタログはリポジトリのトップを拾わない — 名前が決まらず、出すものが無い。
  const fromCatalog = catalog(url);
  if (fromCatalog !== null) {
    const skill = fromCatalog.skill;
    return skill === undefined ? null
      : { url, source: fromCatalog.source, kind: "skill", name: skill, proofs: [] };
  }

  const parts = components(url);
  if (parts === null || parts.branch === undefined || parts.path.length === 0) return null;
  const kind = kindOf(parts.path);
  if (kind === null) return null;
  const source = parseUrl(url);
  if (source === null) return null;

  const file = parts.path.join("/");
  if (kind === "subagent") {
    // Subagent は .md ファイル 1 つ。ディレクトリを指されても中身のファイル名が
    // 分からず確認できないので、その場合は候補にしない。
    if (!parts.isFile) return null;
    const last = parts.path[parts.path.length - 1];
    return { url, source, kind, name: last.replace(/\.md$/, ""), proofs: [file] };
  }

  const directory = parts.isFile ? parts.path.slice(0, -1) : parts.path;
  return {
    url, source, kind,
    name: directory[directory.length - 1] ?? source.repo,
    proofs: [parts.isFile ? file : `${file}/SKILL.md`],
  };
}
