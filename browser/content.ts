/**
 * 見ている URL を service worker へ送るだけ。判定も UI も持たない
 * （content script は ES モジュールを読み込めない）。
 *
 * SPA の遷移は `chrome.webNavigation.onHistoryStateUpdated` が service worker 側で拾う。
 * content script から `history.pushState` を差し替えても、ページ本体は別の JavaScript 世界で
 * 動いているので呼ばれない。ここでやるのは最初の 1 回と、JSON-LD の受け渡しだけにする。
 */
const report = (): void => {
  // URL だけで取得元が決まらないカタログのために、ページの JSON-LD を添える。
  // HTML 全体は送らない。読むのは service worker 側の `fromJsonLd` だけ。
  const jsonLd = [...document.querySelectorAll('script[type="application/ld+json"]')]
    .map(node => node.outerHTML).join("").slice(0, 2 * 1024 * 1024);
  void chrome.runtime.sendMessage({ type: "visited", url: location.href, jsonLd })
    .catch(() => {
      // 拡張の再読み込み中など service worker が一時的に不在でも、ページは動かす。
    });
};

// SPA の遷移を service worker が拾ったら、その時点の URL と JSON-LD を送り直す。
chrome.runtime.onMessage.addListener(message => {
  if ((message as { type?: string }).type === "rescan") report();
});

report();
