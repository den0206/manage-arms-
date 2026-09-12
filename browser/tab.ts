import { Collected } from "../core/collection.js";
import { lead, ToolLead } from "../core/detect.js";
import { fromJsonLd, needsPage } from "../core/github.js";
import { AgentId } from "../core/agent.js";
import { placement, SHARED_SKILL_ROOT, targets } from "../core/placement.js";
import { PAGE_LIMIT } from "../core/limits.js";
import { PickerError, rootHandle } from "./fs.js";
import { install, InstallError, remove, willOverwrite } from "./install.js";
import { bannerEnabled, loadCollection, loadHandle, setBannerEnabled } from "./store.js";

const t = (key: string, ...args: string[]): string => chrome.i18n.getMessage(key, args);
const byId = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;

for (const node of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
  node.textContent = t(node.dataset.i18n ?? "");
}
byId<HTMLInputElement>("url").placeholder = t("tabUrlPlaceholder");

// --- 導入先の選択 -------------------------------------------------------

let current: ToolLead | null = null;
let chosen: AgentId | null = null;

/** 隠しディレクトリはピッカーで見えない。開く前に OS 別の手順を出す。 */
const pickerHint = (root: string): string => {
  const platform = navigator.userAgent;
  const key = platform.includes("Mac") ? "pickerIntroMac"
    : platform.includes("Windows") ? "pickerIntroWindows" : "pickerIntroLinux";
  return t(key, `~/${root}`);
};

async function renderTargets(found: ToolLead): Promise<void> {
  const shared = await loadHandle(SHARED_SKILL_ROOT) !== undefined;
  const box = byId("targets");
  box.replaceChildren();
  chosen = null;

  for (const agent of targets(found.kind)) {
    const where = placement(agent, found.kind, found.name, shared);
    if (where === null) continue;
    const granted = await loadHandle(where.root) !== undefined;

    const label = document.createElement("label");
    const radio = document.createElement("input");
    radio.type = "radio";
    radio.name = "agent";
    radio.value = agent;
    radio.addEventListener("change", () => {
      chosen = agent;
      byId("picker-intro").textContent = granted ? "" : pickerHint(where.root);
    });
    const text = document.createElement("span");
    text.textContent = `${agent} — ~/${where.root}`
      + (granted ? "" : ` (${t("tabNeedsPermission")})`);
    label.append(radio, text);
    box.append(label);
  }
}

/** URL だけで取得元が決まらないカタログは、ページを 1 回読んで JSON-LD から採る。 */
async function resolve(raw: string): Promise<ToolLead | null> {
  const direct = lead(raw);
  if (direct !== null) return direct;
  const page = needsPage(raw);
  if (page === null) return null;
  const response = await fetch(page, { cache: "no-store" }).catch(() => null);
  if (response === null || !response.ok) return null;
  const size = Number(response.headers.get("content-length") ?? 0);
  if (size > PAGE_LIMIT) return null;
  const resolved = fromJsonLd((await response.text()).slice(0, PAGE_LIMIT));
  return resolved === null ? null : lead(resolved);
}

async function showLead(raw: string): Promise<void> {
  const found = await resolve(raw);
  current = found;
  byId("url-error").hidden = found !== null;
  byId("found").hidden = found === null;
  byId("status").textContent = "";
  if (found === null) return;

  byId("found-title").textContent =
    t(found.kind === "skill" ? "bannerSkill" : "bannerSubagent", found.name);
  byId("found-repo").textContent = found.source.repo;
  await renderTargets(found);
}

byId<HTMLInputElement>("url").addEventListener("change", event => {
  void showLead((event.target as HTMLInputElement).value.trim());
});

// --- 導入 ---------------------------------------------------------------

byId<HTMLButtonElement>("install").addEventListener("click", async () => {
  const found = current, agent = chosen;
  const status = byId("status");
  if (found === null || agent === null) return;

  const shared = await loadHandle(SHARED_SKILL_ROOT) !== undefined;
  const where = placement(agent, found.kind, found.name, shared);
  if (where === null) return;

  const button = byId<HTMLButtonElement>("install");
  button.disabled = true;
  status.textContent = t("tabInstalling");
  try {
    const root = await rootHandle(where.root, true);
    if (root === null) { status.textContent = t("permissionLost"); return; }

    const request = { lead: found, agent, placement: where, root };
    const overwrite = await willOverwrite(request)
      ? confirm(t("overwriteConfirm", found.name))
      : true;
    if (!overwrite) { status.textContent = ""; return; }

    await install({ ...request, overwrite: true });
    status.textContent = t("tabInstalled", found.name, `~/${where.root}`);
    await renderCollection();
  } catch (error) {
    status.textContent =
      error instanceof PickerError
        ? (error.kind === "cancelled" ? "" : t("pickerWrongFolder", error.chosen ?? "", `~/${where.root}`))
      : error instanceof InstallError && error.kind === "tooLarge" ? t("errorTooLarge")
      : t("errorFetchFailed");
  } finally {
    button.disabled = false;
  }
});

// --- 収集一覧 -----------------------------------------------------------

async function renderCollection(): Promise<void> {
  const list = await loadCollection();
  const box = byId("collection");
  box.replaceChildren();
  byId("collection-empty").hidden = list.length > 0;

  for (const item of list) {
    const row = document.createElement("li");
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = `${item.name} — ${item.repo} (~/${item.root})`;
    const button = document.createElement("button");
    button.textContent = t("tabRemove");
    button.addEventListener("click", () => void removeItem(item, row));
    row.append(name, button);
    box.append(row);
  }
}

async function removeItem(item: Collected, row: HTMLElement): Promise<void> {
  if (!confirm(t("tabRemoveConfirm", item.name))) return;
  const root = await rootHandle(item.root, true);
  if (root === null) { byId("status").textContent = t("permissionLost"); return; }

  const result = await remove(item, root, item.kind === "skill");
  if (result === "changed") {
    byId("status").textContent = t("tabRemoveChanged", item.name);
    return;
  }
  row.remove();
  await renderCollection();
}

// --- 起動 ---------------------------------------------------------------

const banner = byId<HTMLInputElement>("banner");
banner.addEventListener("change", () => void setBannerEnabled(banner.checked));

void (async () => {
  banner.checked = await bannerEnabled();
  await renderCollection();
  // バナーの「導入する」から来たときは URL がハッシュに乗っている。
  const from = decodeURIComponent(location.hash.slice(1));
  if (from !== "") {
    byId<HTMLInputElement>("url").value = from;
    await showLead(from);
  }
})();
