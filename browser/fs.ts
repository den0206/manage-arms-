import { safeSegments } from "../core/archive.js";
import { TreeFile } from "../core/hash.js";
import { dropHandle, loadHandle, saveHandle } from "./store.js";

/**
 * File System Access API はハンドルから basename しか返さない。絶対パスは持てないので、
 * 利用者には「導入先ルートそのものを選んでください」と頼み、選ばれたものは名前だけで示す。
 */

export class PickerError extends Error {
  constructor(readonly kind: "cancelled" | "wrongFolder", readonly chosen?: string) {
    super(kind);
  }
}

/** 覚えているハンドルを使えるようにする。権限が切れていれば操作の中で訊き直す。 */
async function revive(
  key: string, pick: boolean,
): Promise<FileSystemDirectoryHandle | null> {
  const saved = await loadHandle(key);
  if (saved === undefined) return null;
  if (await saved.queryPermission({ mode: "readwrite" }) === "granted") return saved;
  if (!pick) return null;
  return await saved.requestPermission({ mode: "readwrite" }) === "granted" ? saved : null;
}

/**
 * 置き場のハンドルを得る。`pick` が false ならピッカーを出さない（許可済みかの確認に使う）。
 *
 * 選んでもらうのは `~/.claude` だが、**`~/.claude/skills` を選ばれても受け取る**。
 * 利用者が探しに行くのは「スキルの入っているフォルダ」の方で、そちらを選ぶのが自然だから。
 * 設定ディレクトリを選んでもらえれば `skills` と `agents` の両方を辿れて、ピッカーが 1 回で済む。
 */
export async function placeHandle(
  where: { configDir: string; sub: string }, pick: boolean,
  /** 覚えているものを使わず、必ずピッカーを開く。「選び直す」はこれを使う。 */
  force = false,
): Promise<FileSystemDirectoryHandle | null> {
  if (!force) {
    const config = await revive(where.configDir, pick);
    if (config !== null) return await config.getDirectoryHandle(where.sub, { create: true });

    const direct = await revive(`${where.configDir}/${where.sub}`, pick);
    if (direct !== null) return direct;
  }
  if (!pick) return null;

  let handle: FileSystemDirectoryHandle;
  try {
    // `startIn` は指定しない。ホームは指せず、Documents から始めても遠いだけ。
    // `id` を渡しておくと、2 回目からは前回の場所から開く。
    handle = await showDirectoryPicker({
      id: where.configDir.replace(/[^\w]/g, "_"), mode: "readwrite",
    });
  } catch {
    throw new PickerError("cancelled");
  }

  // 絶対パスは得られないので、確かめられるのは末尾の名前だけ。
  // 設定ディレクトリなら両方を辿れる。置き場そのものならそれだけを覚える。
  // 選び直したときに古い方が残ると、どちらが効いているのか分からなくなる。
  if (handle.name === where.configDir) {
    await dropHandle(`${where.configDir}/${where.sub}`);
    await saveHandle(where.configDir, handle);
    return await handle.getDirectoryHandle(where.sub, { create: true });
  }
  if (handle.name === where.sub) {
    await dropHandle(where.configDir);
    await saveHandle(`${where.configDir}/${where.sub}`, handle);
    return handle;
  }
  throw new PickerError("wrongFolder", handle.name);
}

/**
 * 隠しフォルダはピッカーに出ない。開く前に OS 別の手順を出す。
 * ピッカーの表示は拡張から操作できないので、助けられるのは文言だけ。
 */
export const pickerHint = (path: string): string => {
  const agent = navigator.userAgent;
  const key = agent.includes("Mac") ? "pickerIntroMac"
    : agent.includes("Windows") ? "pickerIntroWindows" : "pickerIntroLinux";
  return chrome.i18n.getMessage(key, [path]);
};


/**
 * 書き込みの失敗は握りつぶさない。`NotAllowedError` なのか `TypeMismatchError` なのかで
 * 手の打ちようが変わるのに、「作れませんでした」だけでは何も分からない。
 */
export class WriteError extends Error {
  constructor(readonly path: string, readonly cause: unknown) {
    const reason = cause instanceof DOMException ? `${cause.name}: ${cause.message}`
      : cause instanceof Error ? cause.message : String(cause);
    super(`${path}: ${reason}`);
  }
}

const dirOf = async (root: FileSystemDirectoryHandle, segments: string[],
                     create: boolean): Promise<FileSystemDirectoryHandle> => {
  let current = root;
  for (const segment of segments) {
    current = await current.getDirectoryHandle(segment, { create });
  }
  return current;
};

/** 展開済みの中身を書き出す。名前の検証は core と同じ `safeSegments` を通す。 */
export async function writeTree(
  root: FileSystemDirectoryHandle, base: string[], files: readonly TreeFile[],
): Promise<void> {
  for (const file of files) {
    const segments = safeSegments(file.path);
    if (segments === null) throw new WriteError(file.path, "unsafe path");
    const full = [...base, ...segments].join("/");
    try {
      const parent = await dirOf(root, [...base, ...segments.slice(0, -1)], true);
      const handle = await parent.getFileHandle(segments[segments.length - 1], { create: true });
      const writable = await handle.createWritable();
      try {
        // DOM 型は SharedArrayBuffer 由来を受けない。実際に渡すのは通常の Uint8Array。
        await writable.write(file.bytes as unknown as BufferSource);
      } finally {
        await writable.close();
      }
    } catch (error) {
      throw error instanceof WriteError ? error : new WriteError(full, error);
    }
  }
}

/** 実体を読み出して hash にかける形にする。削除前の照合と導入直後の記録に使う。 */
export async function readTree(
  root: FileSystemDirectoryHandle, entry: string, isDirectory: boolean,
): Promise<TreeFile[] | null> {
  if (!isDirectory) {
    const file = await root.getFileHandle(entry).catch(() => null);
    if (file === null) return null;
    return [{ path: entry, bytes: new Uint8Array(await (await file.getFile()).arrayBuffer()) }];
  }
  const dir = await root.getDirectoryHandle(entry).catch(() => null);
  if (dir === null) return null;
  const files: TreeFile[] = [];
  const walk = async (handle: FileSystemDirectoryHandle, prefix: string): Promise<void> => {
    for await (const [name, child] of handle.entries()) {
      const path = `${prefix}${name}`;
      if (child.kind === "directory") await walk(child, `${path}/`);
      else files.push({
        path,
        bytes: new Uint8Array(await (await child.getFile()).arrayBuffer()),
      });
    }
  };
  await walk(dir, "");
  return files;
}

/**
 * 置き場を確保する。**作ってみるまで使えるかは分からない。**
 *
 * IDE 拡張が張った symlink は、`getDirectoryHandle` でも `entries()` でも見えないのに
 * 名前は埋まっている。`create: true` で `NotFoundError` になって初めて分かる。
 * 呼び出し側はここで失敗したら「触れない名前」として扱う。
 */
export async function reserve(
  root: FileSystemDirectoryHandle, entry: string, isDirectory: boolean,
): Promise<FileSystemDirectoryHandle | FileSystemFileHandle> {
  try {
    return isDirectory
      ? await root.getDirectoryHandle(entry, { create: true })
      : await root.getFileHandle(entry, { create: true });
  } catch (error) {
    throw new WriteError(entry, error);
  }
}

export const exists = async (root: FileSystemDirectoryHandle, entry: string): Promise<boolean> => {
  const asFile = await root.getFileHandle(entry).then(() => true, () => false);
  return asFile || await root.getDirectoryHandle(entry).then(() => true, () => false);
};

/**
 * 実体 1 件だけを消す。導入先ルートそのものと `.agent-tool` は対象にしない
 * （セキュリティ要件 §10.3）。
 */
export async function removeEntry(
  root: FileSystemDirectoryHandle, entry: string, isDirectory: boolean,
): Promise<void> {
  const segments = safeSegments(entry);
  if (segments === null || segments.length !== 1 || segments[0].startsWith(".")) {
    throw new Error(`refusing to remove ${entry}`);
  }
  await root.removeEntry(segments[0], { recursive: isDirectory });
}
