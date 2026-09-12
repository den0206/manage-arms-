// 組み立てたブラウザ拡張が、読み込む前に壊れていないかを見る。
// manifest と HTML が指すファイル、ESM の import 先、i18n のキーを突き合わせる。
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const root = process.argv[2];
if (root === undefined) {
  console.error("usage: check-browser-package.mjs <dir>");
  process.exit(2);
}

const problems = [];
const check = (path, why) => {
  if (!existsSync(join(root, path))) problems.push(`${why}: ${path} がありません`);
};

const manifest = JSON.parse(readFileSync(join(root, "manifest.json"), "utf8"));

// --- manifest が指すもの ---
check(manifest.background.service_worker, "background");
for (const script of manifest.content_scripts.flatMap(entry => entry.js)) {
  check(script, "content_scripts");
}
check(manifest.options_page, "options_page");
for (const path of Object.values(manifest.icons ?? {})) check(path, "icons");

// service worker は ESM、content script は素のスクリプトでなければ読めない。
const worker = readFileSync(join(root, manifest.background.service_worker), "utf8");
if (manifest.background.type !== "module" && /^import /m.test(worker)) {
  problems.push("background が import を含むのに type: module ではありません");
}
for (const script of manifest.content_scripts.flatMap(entry => entry.js)) {
  const body = readFileSync(join(root, script), "utf8");
  if (/^(import|export) /m.test(body)) {
    problems.push(`${script} は content script なので ESM にできません`);
  }
}

// --- ESM の import 先 ---
const walk = dir => readdirSync(join(root, dir), { withFileTypes: true })
  .flatMap(entry => entry.isDirectory()
    ? walk(join(dir, entry.name))
    : [join(dir, entry.name)]);

for (const file of walk(".").filter(path => path.endsWith(".js"))) {
  const body = readFileSync(join(root, file), "utf8");
  for (const match of body.matchAll(/from\s+"(\.[^"]+)"/g)) {
    const target = relative(resolve(root), resolve(root, dirname(file), match[1]));
    check(target, `${file} の import`);
  }
}

// --- HTML が指すもの ---
for (const file of walk(".").filter(path => path.endsWith(".html"))) {
  const body = readFileSync(join(root, file), "utf8");
  for (const match of body.matchAll(/(?:src|href)="([^"]+)"/g)) {
    if (/^https?:/.test(match[1])) continue;
    check(join(dirname(file), match[1]), `${file} の参照`);
  }
}

// --- i18n のキー ---
const locales = readdirSync(join(root, "_locales"));
const messages = Object.fromEntries(locales.map(locale =>
  [locale, JSON.parse(readFileSync(join(root, "_locales", locale, "messages.json"), "utf8"))]));

const used = new Set();
for (const match of readFileSync(join(root, "manifest.json"), "utf8").matchAll(/__MSG_(\w+)__/g)) {
  used.add(match[1]);
}
for (const file of walk(".").filter(path => path.endsWith(".js") || path.endsWith(".html"))) {
  const body = readFileSync(join(root, file), "utf8");
  for (const match of body.matchAll(/getMessage\(\s*"([^"]+)"/g)) used.add(match[1]);
  for (const match of body.matchAll(/\bt\(\s*"([^"]+)"/g)) used.add(match[1]);
  for (const match of body.matchAll(/data-i18n="([^"]+)"/g)) used.add(match[1]);
}
for (const [locale, table] of Object.entries(messages)) {
  for (const key of used) {
    if (!(key in table)) problems.push(`_locales/${locale}: ${key} がありません`);
  }
}

if (problems.length > 0) {
  console.error("::error::組み立てたブラウザ拡張に不足があります");
  for (const problem of problems) console.error(`  ${problem}`);
  process.exit(1);
}
console.log(`✓ manifest・import・HTML・i18n の参照が揃っています（${locales.join(" / ")}）`);
