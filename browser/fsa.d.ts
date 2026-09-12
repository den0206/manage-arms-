/**
 * TypeScript の DOM 型定義にまだ無い File System Access API の一部。
 * 使う分だけ宣言する（依存を増やさない）。
 */
type FileSystemPermissionMode = "read" | "readwrite";
type PermissionState = "granted" | "denied" | "prompt";

interface FileSystemHandle {
  queryPermission(options?: { mode?: FileSystemPermissionMode }): Promise<PermissionState>;
  requestPermission(options?: { mode?: FileSystemPermissionMode }): Promise<PermissionState>;
}

interface FileSystemDirectoryHandle {
  entries(): AsyncIterableIterator<[string, FileSystemHandle & (FileSystemDirectoryHandle | FileSystemFileHandle)]>;
}

interface Navigator {
  /** Brave だけが持つ。ピッカーを出せないときの案内を分けるのに使う。 */
  readonly brave?: { isBrave(): Promise<boolean> };
}

declare function showDirectoryPicker(options?: {
  id?: string;
  mode?: FileSystemPermissionMode;
  startIn?: FileSystemHandle | string;
}): Promise<FileSystemDirectoryHandle>;
