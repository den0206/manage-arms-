import { DetectKind } from "./detect.js";

/**
 * ブラウザ拡張の収集一覧の 1 件。IndexedDB に置く（設計決定 D-11）。
 * `treeHash` は削除してよいかの判定にだけ使う。
 */
export type Collected = {
  readonly name: string;
  readonly kind: DetectKind;
  readonly agent: string;
  readonly root: string;
  readonly repo: string;
  readonly branch?: string;
  readonly subdir?: string;
  readonly sha?: string;
  /** 導入直後に計算した実体ツリーの SHA-256。 */
  readonly treeHash: string;
  /** 導入時刻（ミリ秒）。退避の順序にだけ使う。 */
  readonly installedAt: number;
};

/** 収集一覧の上限。超えた分は古い順に捨てる。 */
export const MAX_BROWSER_COLLECTION_ENTRIES = 100;

/** 同じ導入先に同じ名前のものは 1 件だけ持つ。 */
const same = (a: Collected, b: Collected): boolean =>
  a.name === b.name && a.kind === b.kind && a.root === b.root && a.agent === b.agent;

/**
 * 1 件足したあとの一覧を返す。上限を超えたら古い順に捨てる。
 * 保存も読み出しもしない純粋関数にして、IndexedDB を持たない環境でも検証できるようにする。
 */
export function add(
  list: readonly Collected[], item: Collected,
  limit = MAX_BROWSER_COLLECTION_ENTRIES,
): Collected[] {
  const kept = list.filter(entry => !same(entry, item));
  const next = [...kept, item].sort((a, b) => a.installedAt - b.installedAt);
  return next.slice(Math.max(0, next.length - limit));
}

export const find = (list: readonly Collected[], item: Pick<Collected,
  "name" | "kind" | "root" | "agent">): Collected | undefined =>
  list.find(entry => same(entry, item as Collected));

/**
 * 削除してよいか。導入時の実体ツリー hash と一致するときだけ許す。
 * 手で書き換えられたもの、IDE 拡張が更新したものは消さない。
 */
export const isRemovable = (entry: Collected | undefined, treeHash: string): boolean =>
  entry !== undefined && entry.treeHash === treeHash;
