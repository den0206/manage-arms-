/**
 * 検知バナー。判定は service worker が持ち、ここは受け取ったものを描くだけにする。
 * content script は ES モジュールを読み込めないので、依存を持たせない。
 *
 * ページの CSS を継承しないよう Shadow DOM に閉じる（設計決定 D-16）。
 */
type Shown = { title: string; repo: string; install: string; dismiss: string; url: string };

const HOST_ID = "agent-tool-banner";

function remove(): void {
  document.getElementById(HOST_ID)?.remove();
}

function show(lead: Shown): void {
  remove();
  const host = document.createElement("div");
  host.id = HOST_ID;
  host.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:2147483647";
  const shadow = host.attachShadow({ mode: "closed" });

  const style = document.createElement("style");
  style.textContent = `
    .bar { display:flex; gap:12px; align-items:center; padding:10px 16px;
           font:14px/1.4 system-ui,-apple-system,sans-serif; color:#0b1220;
           background:#e8f0fe; border-bottom:1px solid #adc6f4; }
    .text { flex:1; min-width:0 }
    .repo { font-size:12px; opacity:.7 }
    button { font:inherit; padding:6px 14px; border-radius:6px; cursor:pointer; border:1px solid #adc6f4 }
    .primary { background:#1a56db; border-color:#1a56db; color:#fff }
    .ghost { background:transparent }
    @media (prefers-color-scheme: dark) {
      .bar { background:#16233c; color:#e6edf7; border-bottom-color:#2b4472 }
      .ghost { color:#e6edf7; border-color:#2b4472 }
    }`;

  const bar = document.createElement("div");
  bar.className = "bar";
  const text = document.createElement("div");
  text.className = "text";
  const title = document.createElement("div");
  title.textContent = lead.title;
  const repo = document.createElement("div");
  repo.className = "repo";
  repo.textContent = lead.repo;
  text.append(title, repo);

  const install = document.createElement("button");
  install.className = "primary";
  install.textContent = lead.install;
  install.addEventListener("click", () => {
    void chrome.runtime.sendMessage({ type: "install", url: lead.url });
    remove();
  });

  const dismiss = document.createElement("button");
  dismiss.className = "ghost";
  dismiss.textContent = lead.dismiss;
  dismiss.addEventListener("click", () => {
    void chrome.runtime.sendMessage({ type: "dismiss", url: lead.url });
    remove();
  });

  bar.append(text, install, dismiss);
  shadow.append(style, bar);
  document.documentElement.append(host);
}

chrome.runtime.onMessage.addListener(message => {
  const payload = message as { type?: string } & Partial<Shown>;
  if (payload.type === "show" && payload.url !== undefined) show(payload as Shown);
  if (payload.type === "hide") remove();
});

// GitHub は pushState で遷移するので load だけでは足りない。Navigation API で拾う
// （Chromium 102 以降。対象は Chrome / Edge だけなのでポーリングは持たない）。
const report = (): void => {
  remove();
  void chrome.runtime.sendMessage({ type: "visited", url: location.href });
};
navigation?.addEventListener("navigate", () => setTimeout(report, 0));
report();
