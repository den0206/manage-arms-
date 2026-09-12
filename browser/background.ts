import { lead, proofUrls, ToolLead } from "../core/detect.js";
import { fromJsonLd, needsPage } from "../core/github.js";
import { splitRoot } from "../core/placement.js";
import { autoOpenEnabled, knownRoots, loadCollection, loadHandle } from "./store.js";

/**
 * 検知の判定はここで行う。content script は URL を送るだけにする
 * （content script は ES モジュールを読み込めない）。
 *
 * 見た URL は保存しない。**タブごと**の候補と、この起動中に断られたものだけをメモリに持つ。
 * タブを移ったり別のページへ行けば候補は消える — 前のページの検知結果を出し続けない。
 */
const candidates = new Map<number, string>();
const dismissed = new Set<string>();
const installed = new Set<string>();

/** 実在確認。**どれか 1 つでも 200 なら本物**。404 と通信失敗は黙る。 */
async function exists(found: ToolLead): Promise<boolean> {
  if (found.proofs.length === 0) return true;
  for (const url of proofUrls(found)) {
    const response = await fetch(url, { method: "HEAD", cache: "no-store" }).catch(() => null);
    if (response?.status === 200) return true;
  }
  return false;
}

/**
 * 既に入っているものを毎回勧めない。許可済みのルートは実態を見る。
 *
 * 名前が一覧に出れば入っているとみなす。IDE 拡張が張った symlink は
 * `getDirectoryHandle` では見つからないので、それだけだと毎回勧めてしまう。
 */
async function alreadyInstalled(found: ToolLead): Promise<boolean> {
  const entry = found.kind === "skill" ? found.name : `${found.name}.md`;
  for (const root of await knownRoots()) {
    const config = await loadHandle(root);
    if (config === undefined || await config.queryPermission({ mode: "read" }) !== "granted") continue;
    // 保存しているのが設定ディレクトリか置き場そのものかで、見る階層が変わる。
    const dirs = splitRoot(root).sub === ""
      ? await Promise.all(["skills", "agents"].map(sub =>
          config.getDirectoryHandle(sub).catch(() => null)))
      : [config];
    for (const dir of dirs) {
      if (dir === null) continue;
      try {
        for await (const [name] of dir.entries()) if (name === entry) return true;
      } catch { /* 読めないルートは判断しない */ }
    }
  }
  return (await loadCollection()).some(item =>
    item.name === found.name && item.kind === found.kind);
}

const clear = async (tabId: number): Promise<void> => {
  if (!candidates.delete(tabId)) return;
  await chrome.action.setBadgeText({ text: "", tabId }).catch(() => { /* タブが閉じた */ });
};

async function visit(url: string, tabId: number | undefined, jsonLd?: string): Promise<void> {
  if (tabId === undefined) return;
  // 遷移したら前のページの検知は無かったことにする。
  if (candidates.get(tabId) !== url) await clear(tabId);
  if (!await autoOpenEnabled()) return;

  const resolved = needsPage(url) === null ? url : fromJsonLd(jsonLd ?? "");
  const found = resolved === null ? null : lead(resolved);
  if (found === null) return;
  if (dismissed.has(found.url) || installed.has(`${found.kind}:${found.name}`)) return;
  if (!await exists(found) || await alreadyInstalled(found)) return;

  candidates.set(tabId, found.url);
  await chrome.action.setBadgeText({ text: "1", tabId }).catch(() => { /* タブが閉じた */ });
  await chrome.action.setBadgeBackgroundColor({ color: "#5b36d6", tabId }).catch(() => { /* 同上 */ });
  // 設定が ON なら popup を開く。開けない場合（Chrome の版や操作の文脈による）は
  // バッジだけにする。**別ウィンドウは作らない** — 見ていたページが隠れる。
  await chrome.action.openPopup().catch(() => { /* バッジで足りる */ });
}

/** 今見ているタブの候補。popup が開いたときに訊く。 */
async function activeCandidate(): Promise<string> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id === undefined ? "" : candidates.get(tab.id) ?? "";
}

async function forgetActive(): Promise<void> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id === undefined) return;
  const url = candidates.get(tab.id);
  if (url !== undefined) dismissed.add(url);
  await clear(tab.id);
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  const payload = message as
    { type?: string; url?: string; jsonLd?: string; name?: string; kind?: string };

  if (payload.type === "visited" && payload.url !== undefined) {
    void visit(payload.url, sender.tab?.id, payload.jsonLd);
    return false;
  }
  if (payload.type === "dismiss") { void forgetActive(); return false; }
  if (payload.type === "installed" && payload.name !== undefined && payload.kind !== undefined) {
    installed.add(`${payload.kind}:${payload.name}`);
    void forgetActive();
    return false;
  }
  if (payload.type === "candidate") {
    void activeCandidate().then(respond);
    return true;                                 // 非同期に返す
  }
  return false;
});

// SPA の遷移。カタログは JSON-LD をページから読む必要があるので、
// URL だけで判定せず content script に送り直してもらう。
chrome.webNavigation.onHistoryStateUpdated.addListener(details => {
  void clear(details.tabId);
  void chrome.tabs.sendMessage(details.tabId, { type: "rescan" })
    .catch(() => { /* content script が入っていないページ */ });
});

chrome.tabs.onRemoved.addListener(tabId => { candidates.delete(tabId); });
