const { test } = require("node:test");
const assert = require("node:assert/strict");
const { gzipSync } = require("node:zlib");
const { readTarGz, safeSegments, ArchiveError } =
  require("../out/core/archive.js");

// --- tar を組み立てる（テスト用。実装側は読むだけ） ---------------------

const BLOCK = 512;

function header(name, size, flag, extra = {}) {
  const block = Buffer.alloc(BLOCK, 0);
  block.write(name.slice(0, 100), 0, "utf8");
  block.write("0000644\0", 100);
  block.write("0000000\0", 108);
  block.write("0000000\0", 116);
  block.write(size.toString(8).padStart(11, "0") + "\0", 124);
  block.write("00000000000\0", 136);
  block.write(flag, 156);
  if (extra.link) block.write(extra.link, 157);
  block.write("ustar\0", 257);
  block.write("00", 263);
  if (extra.prefix) block.write(extra.prefix, 345);
  // チェックサムは読み側で見ていないので空白のままでよい
  block.write("        ", 148);
  return block;
}

const pad = body => {
  const rest = body.length % BLOCK;
  return rest === 0 ? body : Buffer.concat([body, Buffer.alloc(BLOCK - rest, 0)]);
};

/** entries: [name, content|null, flag?, extra?] */
function tarGz(entries) {
  const blocks = [];
  for (const [name, content, flag = content === null ? "5" : "0", extra] of entries) {
    const body = content === null ? Buffer.alloc(0) : Buffer.from(content, "utf8");
    blocks.push(header(name, body.length, flag, extra), pad(body));
  }
  blocks.push(Buffer.alloc(BLOCK * 2, 0));                 // 終端
  return gzipSync(Buffer.concat(blocks));
}

const streamOf = buffer => new ReadableStream({
  start(controller) {
    // 途中で切れたチャンクをまたげることも見る
    for (let at = 0; at < buffer.length; at += 100) {
      controller.enqueue(new Uint8Array(buffer.subarray(at, at + 100)));
    }
    controller.close();
  },
});

const readAll = async buffer => {
  const found = [];
  for await (const entry of readTarGz(streamOf(buffer))) found.push(entry);
  return found;
};

const rejects = (buffer, message) =>
  assert.rejects(() => readAll(buffer), error =>
    error instanceof ArchiveError && error.message.includes(message));

// --- エントリ名の検証 ---------------------------------------------------

test("展開先の外へ出るパスを弾く", () => {
  assert.equal(safeSegments("../escape"), null);
  assert.equal(safeSegments("a/../../b"), null);
  assert.equal(safeSegments("a\\b"), null);
  assert.equal(safeSegments("C:/windows"), null);
  assert.equal(safeSegments("a\0b"), null);
  assert.equal(safeSegments(""), null);
  assert.equal(safeSegments("./"), null);
});

test("普通のパスはセグメントに割る", () => {
  assert.deepEqual(safeSegments("repo-main/skills/pdf/SKILL.md"),
    ["repo-main", "skills", "pdf", "SKILL.md"]);
  assert.deepEqual(safeSegments("./repo-main//a.md"), ["repo-main", "a.md"]);
});

// --- tar.gz の読み取り --------------------------------------------------

test("ファイルとディレクトリを読む", async () => {
  const found = await readAll(tarGz([
    ["repo-main/", null],
    ["repo-main/SKILL.md", "---\nname: pdf\n---\n"],
  ]));
  assert.equal(found.length, 2);
  assert.deepEqual(found[0], { path: ["repo-main"], kind: "directory", bytes: new Uint8Array(0) });
  assert.deepEqual(found[1].path, ["repo-main", "SKILL.md"]);
  assert.equal(new TextDecoder().decode(found[1].bytes), "---\nname: pdf\n---\n");
});

test("512 の倍数でない中身も正しく切り出す", async () => {
  const body = "x".repeat(1000);
  const [entry] = await readAll(tarGz([["a/b.txt", body]]));
  assert.equal(entry.bytes.length, 1000);
  assert.equal(new TextDecoder().decode(entry.bytes), body);
});

test("symlink と hardlink は中身を返さず link として渡す", async () => {
  // リポジトリ直下の CLAUDE.md が symlink というだけで取得ごと諦めさせない。
  // 取り出したいものの中にあるかは呼び出し側が判断する。
  const found = await readAll(tarGz([
    ["a/link", "", "2", { link: "/etc/passwd" }],
    ["a/hard", "", "1", { link: "a/real" }],
    ["a/real.md", "body"],
  ]));
  assert.deepEqual(found.map(entry => entry.kind), ["link", "link", "file"]);
  assert.deepEqual(found[0].bytes, new Uint8Array(0));
  assert.equal(new TextDecoder().decode(found[2].bytes), "body");
});

test("デバイスなどの特殊ファイルを拒否する", async () => {
  await rejects(tarGz([["a/dev", "", "3"]]), "unsupported file type");
});

test("展開先の外へ出るエントリを拒否する", async () => {
  await rejects(tarGz([["../escape.md", "x"]]), "escapes");
});

test("prefix と本体を繋いだ長いパスを読む", async () => {
  const [entry] = await readAll(tarGz([["SKILL.md", "x", "0", { prefix: "repo-main/skills/pdf" }]]));
  assert.deepEqual(entry.path, ["repo-main", "skills", "pdf", "SKILL.md"]);
});

test("pax の長い名前を次のエントリに効かせる", async () => {
  const long = "repo-main/" + "d/".repeat(60) + "SKILL.md";
  const record = `${`${` path=${long}\n`.length + 3}`} path=${long}\n`;
  const found = await readAll(tarGz([
    ["PaxHeader", record, "x"],
    ["ignored-short-name", "body"],
  ]));
  assert.equal(found.length, 1);
  assert.equal(found[0].path.join("/"), long);
});

test("GNU の長い名前も読む", async () => {
  const long = "repo-main/" + "e/".repeat(60) + "SKILL.md";
  const found = await readAll(tarGz([
    ["././@LongLink", long + "\0", "L"],
    ["ignored", "body"],
  ]));
  assert.equal(found[0].path.join("/"), long);
});

test("上限を超えたら読むのをやめる", async () => {
  const many = Array.from({ length: 5 }, (_, index) => [`a/${index}.txt`, "x"]);
  await assert.rejects(async () => {
    for await (const _ of readTarGz(streamOf(tarGz(many)), { entries: 3, single: 10, total: 100 })) { /* 読み進める */ }
  }, error => error instanceof ArchiveError && error.message.includes("too many files"));

  await assert.rejects(async () => {
    for await (const _ of readTarGz(streamOf(tarGz([["a/big.txt", "xxxxx"]])),
      { entries: 10, single: 3, total: 100 })) { /* 読み進める */ }
  }, error => error instanceof ArchiveError && error.message.includes("too large"));

  await assert.rejects(async () => {
    for await (const _ of readTarGz(streamOf(tarGz([["a/1.txt", "xxx"], ["a/2.txt", "xxx"]])),
      { entries: 10, single: 10, total: 5 })) { /* 読み進める */ }
  }, error => error instanceof ArchiveError && error.message.includes("too large"));
});

test("途中で切れたアーカイブを黙って受け入れない", async () => {
  const whole = Buffer.concat([header("a/b.txt", 1000, "0"), Buffer.alloc(200, 0x78)]);
  await rejects(gzipSync(whole), "ended in the middle");
});
