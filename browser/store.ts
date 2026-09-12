import { Collected, add as addCollected, MAX_BROWSER_COLLECTION_ENTRIES } from "../core/collection.js";

/**
 * 永続化するのはディレクトリハンドルと収集一覧だけ（設計決定 D-11）。
 * 閲覧した URL・ログ・診断履歴は持たない。
 */
const DB = "agent-tool";
const HANDLES = "handles";
const COLLECTION = "collection";

const open = (): Promise<IDBDatabase> =>
  new Promise((done, fail) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(HANDLES)) db.createObjectStore(HANDLES);
      if (!db.objectStoreNames.contains(COLLECTION)) db.createObjectStore(COLLECTION);
    };
    request.onsuccess = () => done(request.result);
    request.onerror = () => fail(request.error);
  });

async function run<T>(store: string, mode: IDBTransactionMode,
                      body: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  try {
    return await new Promise<T>((done, fail) => {
      const request = body(db.transaction(store, mode).objectStore(store));
      request.onsuccess = () => done(request.result);
      request.onerror = () => fail(request.error);
    });
  } finally {
    db.close();
  }
}

/** 導入先ルート（ホーム相対）ごとに 1 つのハンドルを覚える。 */
export const saveHandle = (root: string, handle: FileSystemDirectoryHandle): Promise<IDBValidKey> =>
  run(HANDLES, "readwrite", store => store.put(handle, root));

export const loadHandle = (root: string): Promise<FileSystemDirectoryHandle | undefined> =>
  run(HANDLES, "readonly", store => store.get(root));

export const knownRoots = (): Promise<string[]> =>
  run(HANDLES, "readonly", store => store.getAllKeys() as IDBRequest<string[]>);

export const loadCollection = async (): Promise<Collected[]> =>
  (await run<Collected[] | undefined>(COLLECTION, "readonly", store => store.get("list"))) ?? [];

export const saveCollection = (list: readonly Collected[]): Promise<IDBValidKey> =>
  run(COLLECTION, "readwrite", store => store.put(list, "list"));

/** 1 件足して保存する。上限の判断は core の純粋関数に任せる。 */
export async function collect(item: Collected): Promise<Collected[]> {
  const next = addCollected(await loadCollection(), item, MAX_BROWSER_COLLECTION_ENTRIES);
  await saveCollection(next);
  return next;
}

export async function forget(item: Collected): Promise<Collected[]> {
  const next = (await loadCollection()).filter(entry =>
    !(entry.name === item.name && entry.kind === item.kind
      && entry.root === item.root && entry.agent === item.agent));
  await saveCollection(next);
  return next;
}

/** バナーの ON / OFF。設定は 1 つだけなので chrome.storage を使わず既定値と往復する。 */
export const autoOpenEnabled = async (): Promise<boolean> =>
  (await run<boolean | undefined>(COLLECTION, "readonly", store => store.get("autoOpen"))) ?? true;

export const setAutoOpenEnabled = (on: boolean): Promise<IDBValidKey> =>
  run(COLLECTION, "readwrite", store => store.put(on, "autoOpen"));
