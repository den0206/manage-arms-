import { lead, proofUrls, ToolLead } from "../core/detect.js";
import { needsPage, parseUrl } from "../core/github.js";
import { bannerEnabled, knownRoots, loadCollection, loadHandle } from "./store.js";

/**
 * 検知の判定はここで行う。content script は URL を送って結果を描くだけにする
 * （content script は ES モジュールを読み込めない）。
 *
 * 見た URL は保存しない。この起動中の「今はしない」だけをメモリに持つ。
 */
const dismissed = new Set<string>();

/** 実在確認。**どれか 1 つでも 200 なら本物**。404 と通信失敗は黙る。 */
async function exists(found: ToolLead): Promise<boolean> {
  if (found.proofs.length === 0) return true;
  for (const url of proofUrls(found)) {
    const response = await fetch(url, { method: "HEAD", cache: "no-store" }).catch(() => null);
    if (response !== null && response.status === 200) return true;
  }
  return false;
}

/** 既に入っているものを毎回勧めない。許可済みのルートは実態を見る。 */
async function alreadyInstalled(found: ToolLead): Promise<boolean> {
  const entry = found.kind === "skill" ? found.name : `${found.name}.md`;
  for (const root of await knownRoots()) {
    const handle = await loadHandle(root);
    if (handle === undefined) continue;
    if (await handle.queryPermission({ mode: "read" }) !== "granted") continue;
    const hit = found.kind === "skill"
      ? await handle.getDirectoryHandle(entry).then(() => true, () => false)
      : await handle.getFileHandle(entry).then(() => true, () => false);
    if (hit) return true;
  }
  // 許可が無いうちは自分の導入履歴で判定する。
  return (await loadCollection()).some(item =>
    item.name === found.name && item.kind === found.kind);
}

const title = (found: ToolLead): string =>
  chrome.i18n.getMessage(found.kind === "skill" ? "bannerSkill" : "bannerSubagent", found.name);

async function visit(url: string, tabId: number | undefined): Promise<void> {
  if (tabId === undefined || dismissed.has(url)) return;
  if (!await bannerEnabled()) return;

  const found = lead(url);
  // URL だけで取得元が決まらないカタログは、開いているページの DOM から読む。
  // ここでは判定できないので、そのページは候補にしない。
  if (found === null || needsPage(url) !== null) return;
  if (!await exists(found)) return;
  if (await alreadyInstalled(found)) return;

  await chrome.tabs.sendMessage(tabId, {
    type: "show", url,
    title: title(found),
    repo: found.source.repo,
    install: chrome.i18n.getMessage("bannerInstall"),
    dismiss: chrome.i18n.getMessage("bannerDismiss"),
  }).catch(() => { /* タブが閉じた */ });
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  const payload = message as { type?: string; url?: string };
  if (payload.type === "visited" && payload.url !== undefined) {
    void visit(payload.url, sender.tab?.id);
  }
  if (payload.type === "dismiss" && payload.url !== undefined) {
    dismissed.add(payload.url);
  }
  if (payload.type === "install" && payload.url !== undefined) {
    // ピッカーはポップアップから呼べない。専用タブで許可と導入を行う（設計決定 D-17）。
    void chrome.tabs.create({
      url: chrome.runtime.getURL(`browser/tab.html#${encodeURIComponent(payload.url)}`),
    });
  }
  if (payload.type === "supported" && payload.url !== undefined) {
    respond(parseUrl(payload.url) !== null);
  }
  return false;
});

chrome.action.onClicked.addListener(() => {
  void chrome.tabs.create({ url: chrome.runtime.getURL("browser/tab.html") });
});
