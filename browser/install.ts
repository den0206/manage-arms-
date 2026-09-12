import { readTarGz } from "../core/archive.js";
import { Collected } from "../core/collection.js";
import { ToolLead } from "../core/detect.js";
import { GitHubSource } from "../core/github.js";
import { treeHash, TreeFile } from "../core/hash.js";
import { ledger, LEDGER_DIR, ledgerPath } from "../core/ledger.js";
import { SIZE_LIMIT } from "../core/limits.js";
import { Placement } from "../core/placement.js";
import { exists, readTree, removeEntry, writeTree } from "./fs.js";
import { collect, forget } from "./store.js";

/**
 * codeload は tar.gz を返す。gzip は DecompressionStream で解ける。
 * SHA が取れていればそれを指す — 取得と記録がずれないようにする。
 * 取れなければ `HEAD` を使い、既定ブランチ名を推測しない（`master` のリポジトリがある）。
 */
export const archiveUrl = (source: GitHubSource, sha?: string): string =>
  `https://codeload.github.com/${source.repo}/tar.gz/`
  + (sha ?? (source.branch === undefined ? "HEAD" : `refs/heads/${encodeURIComponent(source.branch)}`));

/**
 * 導入時点の commit SHA。台帳に載せておかないと、IDE 拡張が取り込んだ直後に
 * 全件が「更新あり」に見える（`inventory.ts` の `hasUpdate`）。
 * 本文は要らないので bare SHA だけを受ける。
 */
export async function commitSha(source: GitHubSource): Promise<string | undefined> {
  const ref = source.branch ?? "HEAD";
  const response = await fetch(
    `https://api.github.com/repos/${source.repo}/commits/${encodeURIComponent(ref)}`,
    { cache: "no-store", headers: { Accept: "application/vnd.github.sha" } },
  ).catch(() => null);
  if (response === null || !response.ok) return undefined;   // 上限に当たっても導入は止めない
  const sha = (await response.text()).trim();
  return /^[0-9a-f]{40}$/.test(sha) ? sha : undefined;
}

export class InstallError extends Error {
  constructor(readonly kind: "tooLarge" | "fetchFailed" | "notFound", message: string) {
    super(message);
  }
}

type Kept = { readonly inside: string[]; readonly bytes: Uint8Array };

/**
 * カタログ URL は取得元に subdir を持たない。名前のディレクトリで SKILL.md を持つものを探す。
 * 候補が複数あれば浅い方を採る（`skills/pdf` と `examples/pdf` なら前者）。
 */
export function locate(kept: readonly Kept[], name: string): string[] | null {
  const found = kept
    .filter(entry => entry.inside.length >= 2
      && entry.inside[entry.inside.length - 1] === "SKILL.md"
      && entry.inside[entry.inside.length - 2] === name)
    .map(entry => entry.inside.slice(0, -1))
    .sort((a, b) => a.length - b.length);
  return found[0] ?? null;
}

/**
 * 取得して、目的のものだけを取り出す。関係ないエントリはその場で捨てるので、
 * メモリに載るのは導入するものだけになる。
 */
export async function download(lead: ToolLead): Promise<{ files: TreeFile[]; sha?: string }> {
  const sha = await commitSha(lead.source);
  const response = await fetch(archiveUrl(lead.source, sha), { cache: "no-store" });
  if (!response.ok || response.body === null) {
    throw new InstallError("fetchFailed", `the archive could not be fetched (${response.status})`);
  }
  const declared = Number(response.headers.get("content-length") ?? 0);
  if (declared > SIZE_LIMIT) {
    await response.body.cancel();
    throw new InstallError("tooLarge", "the archive is too large");
  }

  const want = lead.source.subdir === undefined ? null : lead.source.subdir.split("/");
  const kept: Kept[] = [];
  for await (const entry of readTarGz(response.body)) {
    if (entry.kind !== "file") continue;
    const inside = entry.path.slice(1);                 // `<repo>-<ref>/` を剥がす
    const wanted = want === null
      ? inside.includes(lead.name)                      // カタログ。ここで大きく絞る
      : want.every((part, index) => inside[index] === part);
    if (wanted) kept.push({ inside, bytes: entry.bytes });
  }

  const base = want ?? locate(kept, lead.name);
  if (base === null) throw new InstallError("notFound", "nothing was found at that path");

  let files = kept
    .filter(entry => base.every((part, index) => entry.inside[index] === part))
    .map(entry => ({ path: entry.inside.slice(base.length).join("/"), bytes: entry.bytes }))
    .filter(file => file.path !== "");
  // Subagent は .md 1 つ。取得元の subdir はその親ディレクトリなので名前で絞る。
  if (lead.kind === "subagent") files = files.filter(file => file.path === `${lead.name}.md`);
  if (files.length === 0) throw new InstallError("notFound", "nothing was found at that path");
  return { files, sha };
}

export type InstallRequest = {
  readonly lead: ToolLead;
  readonly agent: string;
  readonly placement: Placement;
  readonly root: FileSystemDirectoryHandle;
  /** 同名があったときに上書きしてよいか。呼び出し側が利用者に確認してから渡す。 */
  readonly overwrite: boolean;
};

export const willOverwrite = (request: Omit<InstallRequest, "overwrite">): Promise<boolean> =>
  exists(request.root, request.placement.entry);

/** 取得・展開・書き込み・台帳・収集一覧までを 1 回で行う。 */
export async function install(request: InstallRequest): Promise<Collected> {
  const { lead, placement, root } = request;
  if (!request.overwrite && await exists(root, placement.entry)) {
    throw new InstallError("notFound", "it already exists");
  }
  const { files, sha } = await download(lead);

  const base = placement.isDirectory ? [placement.entry] : [];
  const laid = placement.isDirectory
    ? files
    : [{ path: placement.entry, bytes: files[0].bytes }];
  await writeTree(root, base, laid);

  // 台帳は IDE 拡張へ取得元を渡すためだけのもの。削除の可否には使わない。
  await writeTree(root, [], [{
    path: ledgerPath(lead.name),
    bytes: new TextEncoder().encode(
      JSON.stringify(ledger(lead.name, lead.kind, lead.source, sha), null, 2) + "\n"),
  }]);

  const written = await readTree(root, placement.entry, placement.isDirectory);
  const item: Collected = {
    name: lead.name, kind: lead.kind, agent: request.agent, root: placement.root,
    repo: lead.source.repo,
    ...(lead.source.branch === undefined ? {} : { branch: lead.source.branch }),
    ...(lead.source.subdir === undefined ? {} : { subdir: lead.source.subdir }),
    ...(sha === undefined ? {} : { sha }),
    treeHash: await treeHash(written ?? []),
    installedAt: Date.now(),
  };
  await collect(item);
  return item;
}

/**
 * 削除。導入時の実体ツリー hash と一致するときだけ消す。
 * 手で直されたもの、IDE 拡張が更新したものは消さない。
 */
export async function remove(
  item: Collected, root: FileSystemDirectoryHandle, isDirectory: boolean,
): Promise<"removed" | "changed" | "missing"> {
  const entry = isDirectory ? item.name : `${item.name}.md`;
  const current = await readTree(root, entry, isDirectory);
  if (current === null) {
    await forget(item);
    return "missing";
  }
  if (await treeHash(current) !== item.treeHash) return "changed";

  await removeEntry(root, entry, isDirectory);
  // 未取り込みの台帳が残っていると、IDE 拡張が消えた実体を登録してしまう。
  await root.getDirectoryHandle(LEDGER_DIR)
    .then(dir => dir.removeEntry(`${item.name}.json`))
    .catch(() => { /* 取り込み済みか、そもそも無い */ });
  await forget(item);
  return "removed";
}
