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

declare function showDirectoryPicker(options?: {
  id?: string;
  mode?: FileSystemPermissionMode;
  startIn?: FileSystemHandle | string;
}): Promise<FileSystemDirectoryHandle>;

/** Navigation API（Chromium 102 以降）。TypeScript の DOM 型定義にまだ無い。 */
declare const navigation: { addEventListener(type: "navigate", handler: () => void): void } | undefined;
