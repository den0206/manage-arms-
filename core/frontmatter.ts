/** SKILL.md の frontmatter。一覧に必要なのは name と description だけ。 */
export type Frontmatter = {
  name?: string;
  description?: string;
  /** Subagent の判定に使う。SKILL.md には無く、Subagent の .md にはある。 */
  tools?: string;
};

export type FrontmatterResult =
  | { status: "parsed"; matter: Frontmatter }
  /** 先頭が `---` で始まっていない。 */
  | { status: "missing" }
  /**
   * 読み取った範囲内に閉じ `---` が無い。4 KB しか読まない設計の副作用なので
   * 「description 無し」と混同せず、UI では区別して出す。
   */
  | { status: "truncated" };

/** 先頭からこのバイト数だけ読む。本文はメモリに載せない。 */
export const HEAD_BYTES = 4096;

export function parse(text: string): FrontmatterResult {
  const lines = text.replace(/\r\n/g, "\n").replace(/^﻿/, "").split("\n");
  if (lines[0]?.trim() !== "---") return { status: "missing" };
  const body = lines.slice(1);
  // 本文中の `---` に引っかからないよう、行全体が `---` のものだけを閉じとみなす。
  const end = body.findIndex(line => line.trim() === "---");
  if (end < 0) return { status: "truncated" };
  return { status: "parsed", matter: parseBody(body.slice(0, end)) };
}

function parseBody(lines: string[]): Frontmatter {
  const matter: Frontmatter = {};
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (line.startsWith(" ") || line.startsWith("\t")) continue;
    const colon = line.indexOf(":");
    if (colon < 0) continue;

    const key = line.slice(0, colon).trim();
    let value = line.slice(colon + 1).trim();

    // YAML ブロックスカラー（`>` `>-` `|` `|-`）。実在するスキルの大半がこの形式。
    if (value.startsWith(">") || value.startsWith("|")) {
      const fold = value.startsWith(">");
      const block: string[] = [];
      while (index + 1 < lines.length) {
        const next = lines[index + 1];
        if (next !== "" && !next.startsWith(" ") && !next.startsWith("\t")) break;
        block.push(next.trim());
        index++;
      }
      while (block.length > 0 && block[block.length - 1] === "") block.pop();
      value = block.join(fold ? " " : "\n");
    } else {
      value = unquote(value);
    }

    if (value === "") continue;
    if (key === "name") matter.name = value;
    else if (key === "description") matter.description = value;
    else if (key === "tools") matter.tools = value;
  }
  return matter;
}

function unquote(value: string): string {
  const quote = value[0];
  if (value.length >= 2 && (quote === "\"" || quote === "'") && value.endsWith(quote)) {
    return value.slice(1, -1);
  }
  return value;
}
