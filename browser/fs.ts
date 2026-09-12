import { safeSegments } from "../core/archive.js";
import { TreeFile } from "../core/hash.js";
import { loadHandle, saveHandle } from "./store.js";

/**
 * File System Access API はハンドルから basename しか返さない。絶対パスは持てないので、
 * 利用者には「導入先ルートそのものを選んでください」と頼み、選ばれたものは名前だけで示す。
 */

export class PickerError extends Error {
  constructor(readonly kind: "cancelled" | "wrongFolder", readonly chosen?: string) {
    super(kind);
  }
}

const lastSegment = (root: string): string => root.slice(root.lastIndexOf("/") + 1);

/**
 * 導入先ルートのハンドルを得る。覚えていれば再利用し、権限が切れていれば
 * 利用者の操作の中で requestPermission を呼ぶ（ブラウザ再起動ごとに 1 回）。
 */
export async function rootHandle(
  root: string, pick: boolean,
): Promise<FileSystemDirectoryHandle | null> {
  const saved = await loadHandle(root);
  if (saved !== undefined) {
    if (await saved.queryPermission({ mode: "readwrite" }) === "granted") return saved;
    if (!pick) return null;
    if (await saved.requestPermission({ mode: "readwrite" }) === "granted") return saved;
  }
  if (!pick) return null;

  let handle: FileSystemDirectoryHandle;
  try {
    handle = await showDirectoryPicker({ id: root.replace(/[^\w]/g, "_"), mode: "readwrite" });
  } catch {
    throw new PickerError("cancelled");
  }
  // 取り違えは検出できない（`~/.cursor/skills` も `~/.claude/skills` も name は `skills`）。
  // せめて末尾の名前だけは見て、明らかに違うものは受け取らない。
  if (handle.name !== lastSegment(root)) throw new PickerError("wrongFolder", handle.name);
  await saveHandle(root, handle);
  return handle;
}

const dirOf = async (root: FileSystemDirectoryHandle, segments: string[],
                     create: boolean): Promise<FileSystemDirectoryHandle | null> => {
  let current = root;
  for (const segment of segments) {
    try {
      current = await current.getDirectoryHandle(segment, { create });
    } catch {
      return null;
    }
  }
  return current;
};

/** 展開済みの中身を書き出す。名前の検証は core と同じ `safeSegments` を通す。 */
export async function writeTree(
  root: FileSystemDirectoryHandle, base: string[], files: readonly TreeFile[],
): Promise<void> {
  for (const file of files) {
    const segments = safeSegments(file.path);
    if (segments === null) throw new Error(`unsafe path: ${file.path}`);
    const parent = await dirOf(root, [...base, ...segments.slice(0, -1)], true);
    if (parent === null) throw new Error(`could not create ${file.path}`);
    const handle = await parent.getFileHandle(segments[segments.length - 1], { create: true });
    const writable = await handle.createWritable();
    try {
      // DOM 型は SharedArrayBuffer 由来を受けない。実際に渡すのは通常の Uint8Array。
      await writable.write(file.bytes as unknown as BufferSource);
    } finally {
      await writable.close();
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
