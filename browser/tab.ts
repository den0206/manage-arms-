import { AgentId } from "../core/agent.js";
import { Collected } from "../core/collection.js";
import { lead, ToolLead } from "../core/detect.js";
import { fromJsonLd, needsPage } from "../core/github.js";
import { PAGE_LIMIT } from "../core/limits.js";
import { placement, rootOf, SHARED_CONFIG_DIR, splitRoot, targets } from "../core/placement.js";
import { configHandle, exists, PickerError, placeHandle } from "./fs.js";
import { install, InstallError, remove, willOverwrite } from "./install.js";
import { autoOpenEnabled, forget, loadCollection, setAutoOpenEnabled } from "./store.js";

const t = (key: string, ...args: string[]): string => chrome.i18n.getMessage(key, args);
const byId = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;
/** `.claude` → `agentClaude`。設定画面と同じ言葉を使う。 */
const agentLabel = (configDir: string): string =>
  t(`agent${configDir.slice(1, 2).toUpperCase()}${configDir.slice(2)}`);
const send = (message: Record<string, unknown>): Promise<unknown> =>
  chrome.runtime.sendMessage(message).catch(() => undefined);

for (const node of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
  node.textContent = t(node.dataset.i18n ?? "");
}
for (const node of document.querySelectorAll<HTMLElement>("[data-i18n-title]")) {
  node.title = t(node.dataset.i18nTitle ?? "");
}
byId<HTMLInputElement>("url").placeholder = t("tabUrlPlaceholder");

let current: ToolLead | null = null;
let chosen: AgentId | null = null;

// --- 導入先の選択 -------------------------------------------------------

async function renderTargets(found: ToolLead): Promise<void> {
  const shared = await configHandle(SHARED_CONFIG_DIR, false) !== null;
  const box = byId("targets");
  box.replaceChildren();
  chosen = null;

  for (const agent of targets(found.kind)) {
    const where = placement(agent, found.kind, found.name, shared);
    if (where === null) continue;
    const granted = await configHandle(where.configDir, false) !== null;

    const label = document.createElement("label");
    label.className = "target";
    const radio = document.createElement("input");
    radio.type = "radio";
    radio.name = "agent";
    radio.value = agent;
    radio.addEventListener("change", () => { chosen = agent; });

    const text = document.createElement("span");
    const name = document.createElement("span");
    name.className = "target-name";
    name.textContent = agentLabel(where.configDir);
    const path = document.createElement("code");
    path.textContent = `~/${rootOf(where)}`;
    text.append(name, path);
    if (!granted) {
      const badge = document.createElement("span");
      badge.className = "badge";
      badge.textContent = t("tabNeedsPermission");
      text.append(badge);
    }
    label.append(radio, text);
    box.append(label);
  }
  // 選択肢が 1 つなら選ばせない。押す回数を増やさない。
  const only = box.querySelector<HTMLInputElement>("input[type=radio]");
  if (box.children.length === 1 && only !== null) { only.checked = true; chosen = only.value as AgentId; }
}

/** URL だけで取得元が決まらないカタログは、ページを 1 回読んで JSON-LD から採る。 */
async function resolve(raw: string): Promise<ToolLead | null> {
  const direct = lead(raw);
  if (direct !== null) return direct;
  const page = needsPage(raw);
  if (page === null) return null;
  const response = await fetch(page, { cache: "no-store" }).catch(() => null);
  if (response === null || !response.ok) return null;
  if (Number(response.headers.get("content-length") ?? 0) > PAGE_LIMIT) return null;
  const resolved = fromJsonLd((await response.text()).slice(0, PAGE_LIMIT));
  return resolved === null ? null : lead(resolved);
}

function setMode(detected: boolean): void {
  document.body.classList.toggle("detected", detected);
  byId("found").hidden = !detected;
}

async function showLead(raw: string): Promise<void> {
  const found = await resolve(raw);
  current = found;
  byId("url-error").hidden = found === null || raw === "";
  byId("status").textContent = "";
  byId("status").className = "status";
  byId<HTMLButtonElement>("install").hidden = false;
  setMode(found !== null);
  if (found === null) return;

  byId("found-kind").textContent = t(found.kind === "skill" ? "kindSkill" : "kindSubagent");
  byId("found-name").textContent = found.name;
  byId("found-repo").textContent = found.source.repo;
  await renderTargets(found);
}

/** 検知の表示をやめて通常の画面に戻す。導入後とタブを移ったときに呼ぶ。 */
function backToNormal(): void {
  current = null;
  chosen = null;
  setMode(false);
  byId<HTMLInputElement>("url").value = "";
  byId("url-error").hidden = true;
}

byId<HTMLInputElement>("url").addEventListener("change", event => {
  const value = (event.target as HTMLInputElement).value.trim();
  if (value === "") { backToNormal(); return; }
  void showLead(value);
});

byId<HTMLButtonElement>("dismiss").addEventListener("click", () => {
  void send({ type: "dismiss" });
  backToNormal();
});

// --- 導入 ---------------------------------------------------------------

byId<HTMLButtonElement>("install").addEventListener("click", async () => {
  const found = current, agent = chosen;
  const status = byId("status");
  if (found === null) return;
  if (agent === null) { status.className = "status error"; status.textContent = t("tabPickTarget"); return; }

  const shared = await configHandle(SHARED_CONFIG_DIR, false) !== null;
  const where = placement(agent, found.kind, found.name, shared);
  if (where === null) return;

  const button = byId<HTMLButtonElement>("install");
  button.disabled = true;
  status.className = "status";
  status.textContent = t("tabInstalling");
  try {
    const root = await placeHandle(where, true);
    if (root === null) { status.textContent = t("permissionLost"); return; }

    const request = { lead: found, agent, placement: where, root };
    if (await willOverwrite(request) && !confirm(t("overwriteConfirm", found.name))) {
      status.textContent = "";
      return;
    }
    await install({ ...request, overwrite: true });
    await send({ type: "installed", name: found.name, kind: found.kind });
    backToNormal();
    await renderCollection();
    const done = byId("done");
    done.textContent = t("tabInstalled", found.name, `~/${rootOf(where)}`);
    done.hidden = false;
    setTimeout(() => { done.hidden = true; }, 6000);
  } catch (error) {
    status.className = "status error";
    status.textContent = message(error, where.configDir);
  } finally {
    button.disabled = false;
  }
});

const message = (error: unknown, configDir: string): string => {
  if (error instanceof PickerError) {
    return error.kind === "cancelled" ? ""
      : t("pickerWrongFolder", error.chosen ?? "", `~/${configDir}`);
  }
  if (error instanceof InstallError) {
    if (error.kind === "tooLarge") return t("errorTooLarge");
    if (error.kind === "notFound") return t("errorNotFound");
  }
  return t("errorFetchFailed");
};

// --- 収集一覧 -----------------------------------------------------------

/** 許可が無いルートは実態を見られない。消えたのか残っているのか決めつけない。 */
type Row = { readonly item: Collected; readonly verified: boolean };

async function reconcile(list: readonly Collected[]): Promise<Row[]> {
  const rows: Row[] = [];
  for (const item of list) {
    const root = await placeHandle(splitRoot(item.root), false);
    if (root === null) { rows.push({ item, verified: false }); continue; }
    const entry = item.kind === "skill" ? item.name : `${item.name}.md`;
    // IDE 側や手で消されていれば、ここで収集一覧から落とす。
    if (await exists(root, entry)) rows.push({ item, verified: true });
    else await forget(item);
  }
  return rows;
}

async function renderCollection(): Promise<void> {
  const rows = await reconcile(await loadCollection());
  const box = byId("collection");
  box.replaceChildren();
  byId("collection-empty").hidden = rows.length > 0;
  byId("verify").hidden = rows.every(row => row.verified);

  for (const { item, verified } of rows) {
    const row = document.createElement("li");
    if (!verified) row.className = "unverified";

    const text = document.createElement("div");
    text.className = "name";
    const name = document.createElement("div");
    name.textContent = item.name;
    const where = document.createElement("code");
    where.textContent = `~/${item.root}`;
    text.append(name, where);

    const button = document.createElement("button");
    button.textContent = t("tabRemove");
    button.addEventListener("click", () => void removeItem(item));

    row.append(text, button);
    box.append(row);
  }
}

/** 許可が切れているルートをまとめて許可し直す。1 回の操作で全部を訊く。 */
byId<HTMLButtonElement>("verify").addEventListener("click", async () => {
  const roots = new Set((await loadCollection()).map(item => splitRoot(item.root).configDir));
  for (const configDir of roots) await configHandle(configDir, true).catch(() => null);
  await renderCollection();
});

async function removeItem(item: Collected): Promise<void> {
  if (!confirm(t("tabRemoveConfirm", item.name))) return;
  const status = byId("status");
  status.className = "status";
  const root = await placeHandle(splitRoot(item.root), true).catch(() => null);
  if (root === null) { status.textContent = t("permissionLost"); return; }

  const result = await remove(item, root, item.kind === "skill");
  if (result === "changed") {
    status.className = "status error";
    status.textContent = t("tabRemoveChanged", item.name);
  }
  await renderCollection();
}

// --- 起動 ---------------------------------------------------------------

const autoOpen = byId<HTMLInputElement>("auto-open");
autoOpen.addEventListener("change", () => void setAutoOpenEnabled(autoOpen.checked));
byId<HTMLButtonElement>("open-settings").addEventListener("click", () => void send({ type: "setup" }));

void (async () => {
  autoOpen.checked = await autoOpenEnabled();
  await renderCollection();
  // 検知の候補は「今見ているタブのもの」だけを受け取る（別のタブのものを出さない）。
  const candidate = await send({ type: "candidate" });
  if (typeof candidate === "string" && candidate !== "") {
    byId<HTMLInputElement>("url").value = candidate;
    await showLead(candidate);
  }
})();
