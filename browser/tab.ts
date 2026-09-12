import { AgentId } from "../core/agent.js";
import { Collected } from "../core/collection.js";
import { lead, ToolLead } from "../core/detect.js";
import { fromJsonLd, needsPage } from "../core/github.js";
import { PAGE_LIMIT } from "../core/limits.js";
import {
  CONFIG_DIRS, placement, Placement, rootOf, RootState, SHARED_CONFIG_DIR, splitRoot, targets,
} from "../core/placement.js";
import { clearRoot, exists, PickerError, pickerHint, placeHandle, rootState } from "./fs.js";
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
byId<HTMLInputElement>("url").placeholder = t("tabUrlPlaceholder");

let current: ToolLead | null = null;
let chosen: AgentId | null = null;

// --- 導入先の選択 -------------------------------------------------------

/** 導入先の候補。選ばれているものを `chosen` に持つ。 */
let options: { agent: AgentId; where: Placement; state: RootState }[] = [];

/**
 * 設定の状態を全エージェント分まとめて読む。
 *
 * **実際の許可は見ない。** File System Access API の許可は origin のタブが全部閉じると
 * 消えるので、popup では毎回「未許可」になる。利用者が決めたのは「どのフォルダを使うか」
 * なので、覚えているかどうかで見せる。足りない許可は導入を押したときに 1 回訊けばよい。
 */
async function readRoots(): Promise<Map<string, RootState>> {
  const pairs = await Promise.all(
    CONFIG_DIRS.map(async configDir => [configDir, await rootState(configDir)] as const));
  return new Map(pairs);
}

const stateLabel = (state: RootState): string =>
  state.kind === "ok" ? ""
    : state.kind === "unset" ? `（${t("tabNeedsPermission")}）`
    : `（${t("rootMismatchShort", state.chosen)}）`;

/** 選択に合わせて、入る場所と足りない設定を出し分ける。 */
function showTarget(): void {
  const picked = options.find(option => option.agent === chosen);
  const path = byId("target-path");
  const hint = byId("picker-hint");
  path.textContent = picked === undefined ? "" : `~/${rootOf(picked.where)}`;
  path.className = "repo";
  hint.className = "hint";
  hint.textContent = "";
  if (picked === undefined || picked.state.kind === "ok") return;

  if (picked.state.kind === "unset") {
    hint.textContent = pickerHint(`~/${picked.where.configDir}`);
    return;
  }
  // 別のフォルダが設定されている。入る先が違うので、赤字で示して導入も止める。
  path.className = "repo error";
  path.textContent = `~/${picked.where.configDir} → ${picked.state.chosen}`;
  hint.className = "hint error";
  hint.textContent = t("rootMismatch", `~/${picked.where.configDir}`, picked.state.chosen);
}

async function renderTargets(found: ToolLead): Promise<void> {
  const roots = await readRoots();
  const stateOf = (configDir: string): RootState =>
    roots.get(configDir) ?? { kind: "unset" };
  const shared = stateOf(SHARED_CONFIG_DIR).kind === "ok";
  const select = byId<HTMLSelectElement>("target");
  select.replaceChildren();
  options = [];

  for (const agent of targets(found.kind)) {
    const where = placement(agent, found.kind, found.name, shared);
    if (where === null) continue;
    const state = stateOf(where.configDir);
    options.push({ agent, where, state });

    const option = document.createElement("option");
    option.value = agent;
    option.textContent = `${agentLabel(where.configDir)}${stateLabel(state)}`;
    select.append(option);
  }
  // 正しく設定されているものがあればそれを初期値にする。無ければ先頭。
  chosen = (options.find(option => option.state.kind === "ok") ?? options[0])?.agent ?? null;
  if (chosen !== null) select.value = chosen;
  showTarget();
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
  byId("picker-hint").textContent = "";
  setMode(found !== null);
  if (found === null) return;

  byId("found-kind").textContent = t(found.kind === "skill" ? "kindSkill" : "kindSubagent");
  byId("found-name").textContent = found.name;
  byId("found-repo").textContent = found.source.repo;
  byId("destination").hidden = true;             // 導入を押してから出す
}

/** 検知の表示をやめて通常の画面に戻す。導入後とタブを移ったときに呼ぶ。 */
function backToNormal(): void {
  current = null;
  chosen = null;
  byId("destination").hidden = true;
  setMode(false);
  byId<HTMLInputElement>("url").value = "";
  byId("url-error").hidden = true;
}

byId<HTMLInputElement>("url").addEventListener("change", event => {
  const value = (event.target as HTMLInputElement).value.trim();
  if (value === "") { backToNormal(); return; }
  void showLead(value);
});

byId<HTMLSelectElement>("target").addEventListener("change", event => {
  chosen = (event.target as HTMLSelectElement).value as AgentId;
  showTarget();
});

byId<HTMLButtonElement>("dismiss").addEventListener("click", () => {
  void send({ type: "dismiss" });
  backToNormal();
});

// --- 導入 ---------------------------------------------------------------

byId<HTMLButtonElement>("install").addEventListener("click", async () => {
  const found = current;
  const status = byId("status");
  if (found === null) return;

  // 検知の時点では種類と名前だけを出している。どこへ入れるかはここで見せる。
  if (byId("destination").hidden) {
    byId("destination").hidden = false;
    await renderTargets(found);
    return;
  }

  const picked = options.find(option => option.agent === chosen);
  if (picked === undefined) {
    status.className = "status error";
    status.textContent = t("tabPickTarget");
    return;
  }
  const { agent, where } = picked;
  // 別のフォルダが設定されたままなら入れない。意図しない場所へ書かない。
  if (picked.state.kind === "mismatch") {
    status.className = "status error";
    status.textContent = t("rootMismatch", `~/${where.configDir}`, picked.state.chosen);
    return;
  }

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
    status.textContent = message(error, where);
  } finally {
    button.disabled = false;
  }
});

const message = (error: unknown, where: Placement): string => {
  if (error instanceof PickerError) {
    return error.kind === "cancelled" ? ""
      : t("pickerWrongFolder", error.chosen ?? "", `~/${where.configDir}`);
  }
  if (error instanceof InstallError) {
    if (error.kind === "tooLarge") return t("errorTooLarge");
    if (error.kind === "notFound") return t("errorNotFound");
    if (error.kind === "blocked") return t("errorBlocked", `~/${rootOf(where)}/${where.entry}`);
    return t("errorFetchFailed");
  }
  // 想定していない失敗を「接続を確かめて」で塗りつぶさない。理由をそのまま見せる。
  console.error("Agent Tool:", error);
  return error instanceof Error ? error.message : String(error);
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
  const roots = new Set((await loadCollection()).map(item => item.root));
  for (const root of roots) await placeHandle(splitRoot(root), true).catch(() => null);
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

// --- 設定。別タブへ飛ばさず popup の中で切り替える ----------------------

function setSettings(open: boolean): void {
  document.body.classList.toggle("settings", open);
  byId("settings-view").hidden = !open;
  if (open) void renderRoots();
}

async function renderRoots(): Promise<void> {
  const roots = await readRoots();
  const box = byId("roots");
  box.replaceChildren();

  for (const configDir of CONFIG_DIRS) {
    const state = roots.get(configDir) ?? { kind: "unset" as const };
    const row = document.createElement("div");
    row.className = state.kind === "mismatch" ? "root bad" : "root";

    const text = document.createElement("div");
    const name = document.createElement("div");
    name.className = "root-name";
    name.textContent = agentLabel(configDir);
    const path = document.createElement("code");
    text.append(name, path);

    if (state.kind === "mismatch") {
      // 設定されているフォルダを赤字で見せる。何が入っているのか分からないまま
      // 「選び直す」とだけ言われても直しようがない。
      path.className = "error";
      path.textContent = `~/${configDir} → ${state.chosen}`;
      const why = document.createElement("div");
      why.className = "error";
      why.textContent = t("rootMismatch", `~/${configDir}`, state.chosen);
      text.append(why);
    } else {
      path.textContent = `~/${configDir}`;
    }

    const actions = document.createElement("div");
    actions.className = "root-actions";

    const button = document.createElement("button");
    button.textContent = state.kind === "ok" ? t("settingsGranted") : t("settingsChoose");
    if (state.kind !== "ok") button.className = "primary";
    button.addEventListener("click", () => void grant(configDir, state.kind !== "unset"));
    actions.append(button);

    // 設定してあるときだけ取り消せる。間違ったフォルダを入れたまま直せないと困る。
    if (state.kind !== "unset") {
      const clear = document.createElement("button");
      clear.className = "clear";
      clear.type = "button";
      clear.title = t("settingsClear");
      clear.setAttribute("aria-label", t("settingsClear"));
      clear.textContent = "×";
      clear.addEventListener("click", async () => {
        await clearRoot(configDir);
        byId("settings-status").textContent = "";
        await renderRoots();
      });
      actions.append(clear);
    }

    row.append(text, actions);
    box.append(row);
  }
}

/** `again` が真なら、覚えているフォルダを使わず必ずピッカーを開く。 */
async function grant(configDir: string, again: boolean): Promise<void> {
  const status = byId("settings-status");
  status.className = "status";
  status.textContent = "";
  try {
    const handle = await placeHandle({ configDir, sub: "skills" }, true, again);
    if (handle !== null) status.textContent = t("settingsSaved", `~/${configDir}`);
    await renderRoots();
  } catch (error) {
    if (error instanceof PickerError && error.kind !== "cancelled") {
      status.className = "status error";
      status.textContent = t("pickerWrongFolder", error.chosen ?? "", `~/${configDir}`);
    }
    // 失敗しても状態は変わっている。いま何が設定されているかを出し直す。
    await renderRoots();
  }
}

byId("hint").textContent = pickerHint("~/.claude");
byId<HTMLButtonElement>("open-settings").addEventListener("click", () => setSettings(true));
byId<HTMLButtonElement>("close-settings").addEventListener("click", () => setSettings(false));

// --- 起動 ---------------------------------------------------------------

const autoOpen = byId<HTMLInputElement>("auto-open");
autoOpen.addEventListener("change", () => void setAutoOpenEnabled(autoOpen.checked));

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
