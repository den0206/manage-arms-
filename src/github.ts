/** 取得元。`git clone` は使わず zipball を落とす。 */
export type GitHubSource = {
  readonly repo: string;        // "owner/name"
  readonly branch?: string;     // 未指定 = 既定ブランチ
  readonly subdir?: string;     // 未指定 = リポジトリ直下
  /**
   * ブランチ名に "/" を含む可能性があり、branch と subdir の境界が確定できない。
   * `tree/feature/x/skills/foo` は `feature/x` + `skills/foo` とも
   * `feature` + `x/skills/foo` とも読める。確認画面で直せるようにする。
   */
  readonly branchAmbiguous?: boolean;
};

export function archiveUrl(source: GitHubSource, defaultBranch = "main", revision?: string): string {
  const reference = revision ?? `refs/heads/${source.branch ?? defaultBranch}`;
  return `https://github.com/${source.repo}/archive/${reference}.zip`;
}

/** `owner/name` として妥当か。パス要素として使う前に必ず通す。 */
const isRepoPath = (owner: string, name: string): boolean =>
  /^[\w.-]+$/.test(owner) && /^[\w.-]+$/.test(name)
  && !owner.startsWith(".") && !name.startsWith(".");

function toUrl(raw: string, hosts: string[]): URL | null {
  let text = raw.trim();
  if (hosts.some(host => text.startsWith(host + "/") || text.startsWith(`www.${host}/`))) {
    text = "https://" + text;                       // スキーム省略を受ける
  }
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  if (!hosts.includes(host)) return null;
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  return url;
}

/** URL を repo / branch / それ以降のパスに割る。同じ解釈を 2 か所に書かない。 */
export type Components = {
  readonly repo: string;
  readonly branch?: string;
  /** ブランチより後ろの全セグメント。blob ならファイル名を含む。 */
  readonly path: string[];
  readonly isFile: boolean;
};

export function components(raw: string): Components | null {
  const url = toUrl(raw, ["github.com"]);
  if (url === null) return null;

  const parts = url.pathname.split("/").filter(part => part !== "");
  if (parts.length < 2) return null;
  const [owner, rawName, ...rest] = parts;
  const name = rawName.endsWith(".git") ? rawName.slice(0, -4) : rawName;
  if (!isRepoPath(owner, name)) return null;
  const repo = `${owner}/${name}`;

  const marker = rest[0];
  if (marker !== "tree" && marker !== "blob") {
    // /issues や /pulls はリポジトリの指定ではない。
    return rest.length === 0 ? { repo, path: [], isFile: false } : null;
  }
  const reference = rest.slice(1);
  if (reference.length === 0) return { repo, path: [], isFile: false };
  return { repo, branch: reference[0], path: reference.slice(1), isFile: marker === "blob" };
}

/**
 * 受ける形:
 *   https://github.com/owner/repo[.git]
 *   github.com/owner/repo                       (スキーム省略)
 *   .../tree/main[/skills/foo]                  (ブランチ・サブディレクトリ)
 *   .../blob/main/skills/foo/SKILL.md           (ファイル指定 → 親を採る)
 *   https://skills.sh/owner/repo/skill          (カタログ → owner/repo を採る)
 */
export function parseUrl(raw: string): GitHubSource | null {
  const fromCatalog = catalog(raw);
  if (fromCatalog !== null) return fromCatalog.source;

  const parts = components(raw);
  if (parts === null) return null;
  if (parts.branch === undefined) return { repo: parts.repo };

  const path = parts.isFile ? parts.path.slice(0, -1) : parts.path;   // SKILL.md → 親
  return {
    repo: parts.repo,
    branch: parts.branch,
    subdir: path.length === 0 ? undefined : path.join("/"),
    branchAmbiguous: parts.path.length > 0,
  };
}

/**
 * skills.sh の予約パス。`skills.sh/agent/claude-code` は owner/repo ではないので、
 * repo として受けると存在しないリポジトリを取得しに行く。
 */
const RESERVED: ReadonlySet<string> = new Set([
  "about", "agent", "agents", "api", "docs", "login", "new", "search",
  "terms", "privacy", "_next", "favicon.ico",
]);

/**
 * カタログページ。配布しているのは GitHub なので owner/repo を採る。
 * 3 番目はディレクトリ名であってパスではない（`grilling` の実体は
 * `skills/productivity/grilling`）ので subdir にはできない。候補の絞り込みヒントに使う。
 * ページの HTML から GitHub リンクを拾う方法は採らない — 構造の変更で静かに壊れる。
 */
export function catalog(raw: string): { source: GitHubSource; skill?: string } | null {
  const url = toUrl(raw, ["skills.sh"]);
  if (url === null) return null;
  const parts = url.pathname.split("/").filter(part => part !== "");
  if (parts.length < 2 || RESERVED.has(parts[0].toLowerCase())) return null;
  if (!isRepoPath(parts[0], parts[1])) return null;
  return { source: { repo: `${parts[0]}/${parts[1]}` }, skill: parts[2] };
}

/** カタログ URL に含まれるスキル名。候補一覧の初期絞り込みに使う。 */
export const skillHint = (raw: string): string | undefined => catalog(raw)?.skill;
