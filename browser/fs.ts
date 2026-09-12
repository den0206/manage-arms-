import { safeSegments } from "../core/archive.js";
import { TreeFile } from "../core/hash.js";
import { LEDGER_DIR } from "../core/ledger.js";
import { ENTRY_LIMIT, EXTRACTED_SIZE_LIMIT, SINGLE_FILE_LIMIT } from "../core/limits.js";
import { RootState, rootStateOf } from "../core/placement.js";
import { dropHandle, loadHandle, saveHandle } from "./store.js";

/** File System Access API では絶対パスを持たず、選択された設定ディレクトリ配下だけを扱う。 */

export class PickerError extends Error {
  constructor(
    readonly kind: "cancelled" | "wrongFolder" | "unavailable",
    readonly chosen?: string,
  ) { super(kind); }
}

export const rootState = async (configDir: string): Promise<RootState> =>
  rootStateOf(configDir, (await loadHandle(configDir))?.name ?? null);

export const clearRoot = (configDir: string): Promise<void> => dropHandle(configDir);

async function revive(configDir: string, pick: boolean): Promise<FileSystemDirectoryHandle | null> {
  const saved = await loadHandle(configDir);
  if (saved === undefined || saved.name !== configDir) return null;
  if (await saved.queryPermission({ mode: "readwrite" }) === "granted") return saved;
  if (!pick) return null;
  return await saved.requestPermission({ mode: "readwrite" }) === "granted" ? saved : null;
}

export async function configHandle(
  configDir: string, pick: boolean, force = false,
): Promise<FileSystemDirectoryHandle | null> {
  if (!force) {
    const config = await revive(configDir, pick);
    if (config !== null) return config;
  }
  if (!pick) return null;
  if (typeof showDirectoryPicker !== "function") throw new PickerError("unavailable");

  let handle: FileSystemDirectoryHandle;
  try {
    handle = await showDirectoryPicker({
      id: configDir.replace(/[^\w]/g, "_"), mode: "readwrite",
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") throw new PickerError("cancelled");
    console.error("Agent Tool: showDirectoryPicker", error);
    throw new PickerError("unavailable");
  }
  await saveHandle(configDir, handle);
  if (handle.name !== configDir) throw new PickerError("wrongFolder", handle.name);
  return handle;
}

export async function placeHandle(
  where: { configDir: string; sub: string }, pick: boolean,
  options: { force?: boolean; create?: boolean } = {},
): Promise<FileSystemDirectoryHandle | null> {
  const config = await configHandle(where.configDir, pick, options.force === true);
  if (config === null) return null;
  return await config.getDirectoryHandle(where.sub, { create: options.create === true }).catch(() => null);
}

export const pickerUnavailable = (): string => {
  const key = "brave" in navigator ? "pickerUnavailableBrave" : "pickerUnavailable";
  return chrome.i18n.getMessage(key);
};

export const pickerHint = (path: string): string => {
  const agent = navigator.userAgent;
  const key = agent.includes("Mac") ? "pickerIntroMac"
    : agent.includes("Windows") ? "pickerIntroWindows" : "pickerIntroLinux";
  return chrome.i18n.getMessage(key, [path]);
};

export class WriteError extends Error {
  constructor(readonly path: string, readonly cause: unknown) {
    const reason = cause instanceof DOMException ? `${cause.name}: ${cause.message}`
      : cause instanceof Error ? cause.message : String(cause);
    super(`${path}: ${reason}`);
  }
}

/** 既存ツリーをメモリへ退避・hash化するときの資源上限超過。 */
export class TreeReadLimitError extends Error {
  constructor(readonly kind: "entries" | "single" | "total", readonly path: string) {
    super(kind === "entries" ? "too many files in the existing tree"
      : kind === "single" ? `${path}: an existing file is too large`
      : "the existing tree is too large");
  }
}

export type TreeReadLimits = { readonly entries: number; readonly single: number; readonly total: number };
export const DEFAULT_TREE_READ_LIMITS: TreeReadLimits = {
  entries: ENTRY_LIMIT, single: SINGLE_FILE_LIMIT, total: EXTRACTED_SIZE_LIMIT,
};

const dirOf = async (root: FileSystemDirectoryHandle, segments: string[],
                     create: boolean): Promise<FileSystemDirectoryHandle> => {
  let current = root;
  for (const segment of segments) current = await current.getDirectoryHandle(segment, { create });
  return current;
};

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
      try { await writable.write(file.bytes as unknown as BufferSource); }
      finally { await writable.close(); }
    } catch (error) {
      throw error instanceof WriteError ? error : new WriteError(full, error);
    }
  }
}

/**
 * 実体を読み出して hash / rollback に使う。外部取得物と同じく件数・単一・合計サイズを
 * 走査中に制限し、巨大な既存ディレクトリを無制限に extension context へ載せない。
 */
export async function readTree(
  root: FileSystemDirectoryHandle, entry: string, isDirectory: boolean,
  limits: TreeReadLimits = DEFAULT_TREE_READ_LIMITS,
): Promise<TreeFile[] | null> {
  let entries = 0;
  let total = 0;
  const readFile = async (handle: FileSystemFileHandle, path: string): Promise<TreeFile> => {
    entries += 1;
    if (entries > limits.entries) throw new TreeReadLimitError("entries", path);
    const file = await handle.getFile();
    if (file.size > limits.single) throw new TreeReadLimitError("single", path);
    total += file.size;
    if (total > limits.total) throw new TreeReadLimitError("total", path);
    return { path, bytes: new Uint8Array(await file.arrayBuffer()) };
  };

  if (!isDirectory) {
    const file = await root.getFileHandle(entry).catch(() => null);
    return file === null ? null : [await readFile(file, entry)];
  }
  const dir = await root.getDirectoryHandle(entry).catch(() => null);
  if (dir === null) return null;
  const files: TreeFile[] = [];
  const walk = async (handle: FileSystemDirectoryHandle, prefix: string): Promise<void> => {
    for await (const [name, child] of handle.entries()) {
      const path = `${prefix}${name}`;
      if (child.kind === "directory") await walk(child, `${path}/`);
      else files.push(await readFile(child, path));
    }
  };
  await walk(dir, "");
  return files;
}

export async function reserve(
  root: FileSystemDirectoryHandle, entry: string, isDirectory: boolean,
): Promise<FileSystemDirectoryHandle | FileSystemFileHandle> {
  try {
    return isDirectory
      ? await root.getDirectoryHandle(entry, { create: true })
      : await root.getFileHandle(entry, { create: true });
  } catch (error) { throw new WriteError(entry, error); }
}

export const exists = async (root: FileSystemDirectoryHandle, entry: string): Promise<boolean> => {
  const asFile = await root.getFileHandle(entry).then(() => true, () => false);
  return asFile || await root.getDirectoryHandle(entry).then(() => true, () => false);
};

export async function removeEntry(
  root: FileSystemDirectoryHandle, entry: string, isDirectory: boolean,
): Promise<void> {
  const segments = safeSegments(entry);
  if (segments === null || segments.length !== 1 || segments[0].startsWith(".")) {
    throw new Error(`refusing to remove ${entry}`);
  }
  await root.removeEntry(segments[0], { recursive: isDirectory });
}

export async function removeLedgerFile(root: FileSystemDirectoryHandle, name: string): Promise<void> {
  const segments = safeSegments(name);
  if (segments === null || segments.length !== 1 || segments[0].startsWith(".")) {
    throw new Error(`refusing to remove ledger ${name}`);
  }
  const dir = await root.getDirectoryHandle(LEDGER_DIR);
  await dir.removeEntry(`${segments[0]}.json`);
}
