import { ArchiveError, firstUnwritable, readTarGz } from "../core/archive.js";
import { Collected, isRemovable } from "../core/collection.js";
import { locateSkill, ToolLead } from "../core/detect.js";
import { GitHubSource } from "../core/github.js";
import { treeHash, TreeFile } from "../core/hash.js";
import { ledger, ledgerPath } from "../core/ledger.js";
import { CATALOG_EXTRACT_LIMIT, ENTRY_LIMIT, SINGLE_FILE_LIMIT, SIZE_LIMIT } from "../core/limits.js";
import { Placement, rootOf } from "../core/placement.js";
import { exists, readTree, removeEntry, removeLedgerFile, reserve, writeTree } from "./fs.js";
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
  constructor(
    readonly kind: "tooLarge" | "fetchFailed" | "notFound" | "blocked" | "unusableName",
    message: string,
  ) {
    super(message);
  }
}

/**
 * 取得して、目的のものだけを取り出す。
 *
 * subdir が分かっているときは、その配下だけを残して他をその場で捨てる。
 * カタログ URL は subdir を持たないので一度まとめて持ち、`locateSkill` で
 * ディレクトリ名か SKILL.md の frontmatter `name` を突き合わせて探す。
 */
export async function download(lead: ToolLead): Promise<{ files: TreeFile[]; sha?: string }> {
  const sha = await commitSha(lead.source);
  const response = await fetch(archiveUrl(lead.source, sha), { cache: "no-store" }).catch(() => null);
  if (response === null) {
    throw new InstallError("fetchFailed", "the archive could not be fetched");
  }
  if (response.status === 404) {
    throw new InstallError("notFound", `${lead.source.repo} was not found on GitHub`);
  }
  if (!response.ok || response.body === null) {
    throw new InstallError("fetchFailed", `the archive could not be fetched (${response.status})`);
  }
  const declared = Number(response.headers.get("content-length") ?? 0);
  if (declared > SIZE_LIMIT) {
    await response.body.cancel();
    throw new InstallError("tooLarge", "the archive is too large");
  }

  const want = lead.source.subdir === undefined ? null : lead.source.subdir.split("/");
  const limits = want === null
    ? { entries: ENTRY_LIMIT, single: SINGLE_FILE_LIMIT, total: CATALOG_EXTRACT_LIMIT }
    : undefined;

  const kept: TreeFile[] = [];
  const links: string[] = [];
  try {
    for await (const entry of readTarGz(response.body, limits)) {
      if (entry.kind === "directory") continue;
      const inside = entry.path.slice(1);                 // `<repo>-<ref>/` を剥がす
      if (want !== null && !want.every((part, index) => inside[index] === part)) continue;
      // リンクは書けないので中身を持たない。入れたいものの中にあれば後で止める。
      if (entry.kind === "link") { links.push(inside.join("/")); continue; }
      kept.push({ path: inside.join("/"), bytes: entry.bytes });
    }
  } catch (error) {
    throw error instanceof ArchiveError
      ? new InstallError("tooLarge", error.message) : error;
  }

  const base = want ?? locateSkill(kept, lead.name);
  if (base === null) {
    throw new InstallError("notFound", `${lead.name} was not found in ${lead.source.repo}`);
  }

  // 入れるものの中にリンクがあれば止める。外にあるだけなら関係ない。
  const prefix = `${base.join("/")}/`;
  const inside = links.filter(path => base.length === 0 || path.startsWith(prefix));
  if (inside.length > 0) {
    throw new InstallError("fetchFailed", `${inside[0]} is a link and cannot be installed`);
  }

  let files = kept
    .filter(file => base.every((part, index) => file.path.split("/")[index] === part))
    .map(file => ({ path: file.path.split("/").slice(base.length).join("/"), bytes: file.bytes }))
    .filter(file => file.path !== "");
  // Subagent は .md 1 つ。取得元の subdir はその親ディレクトリなので名前で絞る。
  if (lead.kind === "subagent") files = files.filter(file => file.path === `${lead.name}.md`);
  if (files.length === 0) {
    throw new InstallError("notFound", `${lead.name} was not found in ${lead.source.repo}`);
  }
  return { files, sha };
}

/**
 * カタログ候補を表示してよいか。取得物は保持も書き込みもしない。
 *
 * `null` は「判定できなかった」。取得そのものに失敗しただけなら、そのリポジトリに
 * 入っていないと分かったわけではない。false と混ぜると、通信が一瞬こけただけの候補を
 * 覚え込んで出さなくなる。
 */
export async function isExtractable(lead: ToolLead): Promise<boolean | null> {
  try {
    await download(lead);
    return true;
  } catch (error) {
    return error instanceof InstallError && error.kind !== "fetchFailed" ? false : null;
  }
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
  const taken = await exists(root, placement.entry);
  if (!request.overwrite && taken) {
    throw new InstallError("notFound", "it already exists");
  }

  // 既にあるものは触らずに、まず取得できることを確かめる。取得に失敗したときに
  // 元のものが消えていると、利用者は何も残らないまま元の版も失う。
  if (!taken) {
    // IDE 拡張が張った symlink は一覧にも出ず、作ろうとして初めて失敗する。
    // 取得の前に分かれば、無駄に落とさずに済む。
    try {
      await reserve(root, placement.entry, placement.isDirectory);
    } catch {
      throw new InstallError("blocked", placement.entry);
    }
  }

  let files: TreeFile[];
  let sha: string | undefined;
  try {
    ({ files, sha } = await download(lead));
  } catch (error) {
    // 確保しただけの空の置き場は片付ける。元からあったものには触っていない。
    if (!taken) {
      await removeEntry(root, placement.entry, placement.isDirectory).catch(() => undefined);
    }
    throw error;
  }

  // 書けない名前が 1 つでもあれば、何も消さずにここで止める。消してから気づくと、
  // 旧版も新版も無い状態が残る。macOS で作れても Windows で作れない名前がある。
  const bad = firstUnwritable([placement.entry, ...files.map(file => file.path)]);
  if (bad !== null) {
    if (!taken) {
      await removeEntry(root, placement.entry, placement.isDirectory).catch(() => undefined);
    }
    throw new InstallError("unusableName", bad);
  }

  const base = placement.isDirectory ? [placement.entry] : [];
  const laid = placement.isDirectory
    ? files
    : [{ path: placement.entry, bytes: files[0].bytes }];
  // 上書きは「重ねる」ではなく「置き換える」。重ねると旧版にしか無いファイルが残り、
  // 新旧の混ざったものができる。File System Access API には rename がないため、旧版を
  // 退避してから置換し、失敗時は戻す。
  // ponytail: 退避はメモリ上。ブラウザ API に原子的な rename が入れば一時ファイルへ替える。
  const previous = taken ? await readTree(root, placement.entry, placement.isDirectory) : null;
  if (taken && previous === null) throw new InstallError("blocked", placement.entry);
  let removed = false;
  try {
    if (taken) {
      await removeEntry(root, placement.entry, placement.isDirectory);
      removed = true;
      await reserve(root, placement.entry, placement.isDirectory);
    }
    await writeTree(root, base, laid);
  } catch (error) {
    if (taken && removed && previous !== null) {
      await removeEntry(root, placement.entry, placement.isDirectory).catch(() => undefined);
      await reserve(root, placement.entry, placement.isDirectory)
        .then(() => writeTree(root, base, previous))
        .catch(rollback => console.error("Agent Tool: restore", rollback));
    } else if (!taken) {
      await removeEntry(root, placement.entry, placement.isDirectory).catch(() => undefined);
    }
    throw error;
  }

  // 台帳は IDE 拡張へ取得元を渡すためだけのもの。削除の可否には使わない。
  // 書けなくても導入は済んでいる。収集一覧に載せないと利用者が消せなくなるので止めない。
  await writeTree(root, [], [{
    path: ledgerPath(lead.name),
    bytes: new TextEncoder().encode(
      JSON.stringify(ledger(lead.name, lead.kind, lead.source, sha), null, 2) + "\n"),
  }]).catch(error => { console.error("Agent Tool: ledger", error); });

  const written = await readTree(root, placement.entry, placement.isDirectory);
  const item: Collected = {
    name: lead.name, kind: lead.kind, agent: request.agent, root: rootOf(placement),
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
  if (!isRemovable(item, await treeHash(current))) return "changed";

  await removeEntry(root, entry, isDirectory);
  // 未取り込みの台帳が残っていると、IDE 拡張が消えた実体を登録してしまう。
  await removeLedgerFile(root, item.name)
    .catch(() => { /* 取り込み済みか、そもそも無い */ });
  await forget(item);
  return "removed";
}
