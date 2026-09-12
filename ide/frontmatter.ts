import { closeSync, openSync, readSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";
import { FrontmatterResult, HEAD_BYTES, parse } from "../core/frontmatter";

export { Frontmatter, FrontmatterResult, HEAD_BYTES, parse } from "../core/frontmatter";

export function read(path: string): FrontmatterResult {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return { status: "missing" };
  }
  try {
    const buffer = Buffer.alloc(HEAD_BYTES);
    const bytes = readSync(fd, buffer, 0, HEAD_BYTES, 0);
    // 4 KB 境界が日本語の途中に落ちると U+FFFD になる。
    // StringDecoder は末尾の不完全なバイト列を自分で持ち越すので、断片が文字にならない。
    return parse(new StringDecoder("utf8").write(buffer.subarray(0, bytes)));
  } finally {
    closeSync(fd);
  }
}
