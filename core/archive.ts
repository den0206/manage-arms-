import { ENTRY_LIMIT, EXTRACTED_SIZE_LIMIT, SINGLE_FILE_LIMIT } from "./limits";

/**
 * アーカイブの読み取りと検証。Web 標準だけで書き、IDE 拡張とブラウザ拡張で共有する。
 * zip は `ide/fetcher.ts` が yauzl で読み、tar.gz はここで読む。エントリ名の検証は両方で同じ。
 */

/**
 * アーカイブ内のパスを展開先の相対セグメントに落とす。外へ出るもの、
 * OS によって意味が変わるものは `null`。展開先の連結は呼び出し側が行う。
 */
export function safeSegments(entryName: string): string[] | null {
  if (entryName.includes("\0")) return null;
  const parts = entryName.split("/").filter(part => part !== "" && part !== ".");
  if (parts.some(part => part === ".." || part.includes("\\") || part.includes(":"))) return null;
  return parts.length === 0 ? null : parts;
}

export type TarKind = "file" | "directory";

export type TarEntry = {
  /** 検証済みのセグメント。先頭の `<repo>-<ref>/` はまだ付いている。 */
  readonly path: string[];
  readonly kind: TarKind;
  readonly bytes: Uint8Array;
};

const BLOCK = 512;
const decoder = new TextDecoder();

const text = (block: Uint8Array, offset: number, length: number): string => {
  const raw = block.subarray(offset, offset + length);
  const end = raw.indexOf(0);
  return decoder.decode(end < 0 ? raw : raw.subarray(0, end));
};

/** tar の数値は 8 進数の文字列。末尾に NUL や空白が付く。 */
const octal = (block: Uint8Array, offset: number, length: number): number => {
  const value = parseInt(text(block, offset, length).trim(), 8);
  return Number.isFinite(value) ? value : 0;
};

const isZeroBlock = (block: Uint8Array): boolean => block.every(byte => byte === 0);

class Reader {
  private buffer = new Uint8Array(0);
  private done = false;
  constructor(private readonly source: ReadableStreamDefaultReader<Uint8Array>) {}

  /** 足りなければ読み足す。末尾に達したら `null`。 */
  async take(length: number): Promise<Uint8Array | null> {
    while (this.buffer.length < length && !this.done) {
      const chunk = await this.source.read();
      if (chunk.done) { this.done = true; break; }
      const next = new Uint8Array(this.buffer.length + chunk.value.length);
      next.set(this.buffer);
      next.set(chunk.value, this.buffer.length);
      this.buffer = next;
    }
    if (this.buffer.length < length) return null;
    const head = this.buffer.subarray(0, length);
    this.buffer = this.buffer.subarray(length);
    return head;
  }
}

export class ArchiveError extends Error {}

// 変数に型注釈を置くと、呼び出しの後ろを TypeScript が到達不能と分かる。
const fail: (message: string) => never = message => { throw new ArchiveError(message); };

/**
 * gzip された tar を読む。`DecompressionStream` はブラウザにも Node にもある。
 *
 * 通常ファイルとディレクトリだけを返し、symlink・hardlink・デバイスは拒否する
 * （zip 側と同じ方針）。上限を超えたらその場で失敗させ、残りを読まない。
 */
export async function* readTarGz(
  stream: ReadableStream<Uint8Array>,
  limits = { entries: ENTRY_LIMIT, single: SINGLE_FILE_LIMIT, total: EXTRACTED_SIZE_LIMIT },
): AsyncGenerator<TarEntry> {
  // Node の型定義は DecompressionStream の writable を BufferSource で受ける。ここだけ合わせる。
  const gunzipped = stream.pipeThrough(
    new DecompressionStream("gzip") as never) as ReadableStream<Uint8Array>;
  const reader = new Reader(gunzipped.getReader());
  let entries = 0;
  let total = 0;
  /** pax / GNU の長い名前は次のエントリに効く。 */
  let override: string | null = null;

  while (true) {
    const header = await reader.take(BLOCK);
    if (header === null) return;                 // 終端ブロックが無くても黙って終える
    if (isZeroBlock(header)) return;

    const flag = String.fromCharCode(header[156]);
    const size = octal(header, 124, 12);
    const padded = Math.ceil(size / BLOCK) * BLOCK;

    // 長い名前を運ぶ補助エントリ。名前を覚えて本体へ持ち越す。
    if (flag === "L" || flag === "x" || flag === "X") {
      const body = await reader.take(padded);
      if (body === null) fail("the archive ended in the middle of an entry");
      const raw = decoder.decode(body.subarray(0, size));
      override = flag === "L" ? raw.replace(/\0+$/, "")
        : (/(?:^|\n)\d+ path=([^\n]*)\n/.exec(raw)?.[1] ?? null);
      continue;
    }
    if (flag === "g") { await reader.take(padded); continue; }   // 全体の既定値。使わない

    const prefix = text(header, 345, 155);
    const name = override ?? (prefix === "" ? text(header, 0, 100) : `${prefix}/${text(header, 0, 100)}`);
    override = null;

    if (flag === "1" || flag === "2") fail("the archive contains a link");
    if (flag !== "0" && flag !== "\0" && flag !== "5") {
      fail("the archive contains an unsupported file type");
    }

    const path = safeSegments(name);
    if (path === null) fail("the archive escapes the extraction directory");

    entries += 1;
    if (entries > limits.entries) fail("too many files in the archive");

    if (flag === "5") {
      yield { path, kind: "directory", bytes: new Uint8Array(0) };
      continue;
    }
    if (size > limits.single) fail("an extracted file is too large");
    total += size;
    if (total > limits.total) fail("the extracted archive is too large");

    const body = await reader.take(padded);
    if (body === null) fail("the archive ended in the middle of an entry");
    yield { path, kind: "file", bytes: body.slice(0, size) };
  }
}

/** アーカイブは `<repo>-<ref>/` を 1 段かぶせる。全部が同じ 1 段なら剥がす。 */
export function stripTopLevel(paths: readonly (readonly string[])[]): number {
  const tops = new Set(paths.map(path => path[0]).filter(top => top !== undefined));
  return tops.size === 1 ? 1 : 0;
}
