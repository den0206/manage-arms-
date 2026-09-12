import { CONFIG_DIRS } from "../core/placement.js";
import { configHandle, PickerError } from "./fs.js";
import { knownRoots } from "./store.js";

/**
 * 導入先の許可をまとめて済ませる画面。
 * 選んでもらうのはエージェントの設定ディレクトリ（`~/.claude`）で、`skills` と `agents` は
 * そこから辿る。エージェントごとにピッカーが 1 回で済む。
 */
const t = (key: string, ...args: string[]): string => chrome.i18n.getMessage(key, args);
const byId = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;

for (const node of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
  node.textContent = t(node.dataset.i18n ?? "");
}

/** `.claude` → `agentClaude`。文言のキーは設定ディレクトリから決める。 */
const label = (configDir: string): string =>
  t(`agent${configDir.slice(1, 2).toUpperCase()}${configDir.slice(2)}`);

async function render(): Promise<void> {
  const configured = new Set(await knownRoots());
  const box = byId("roots");
  box.replaceChildren();

  for (const configDir of CONFIG_DIRS) {
    const row = document.createElement("div");
    row.className = "root";

    const text = document.createElement("div");
    const name = document.createElement("div");
    name.className = "root-name";
    name.textContent = label(configDir);
    const path = document.createElement("code");
    path.textContent = `~/${configDir}`;
    text.append(name, path);

    const button = document.createElement("button");
    const done = configured.has(configDir);
    button.textContent = done ? t("settingsGranted") : t("settingsChoose");
    button.className = done ? "" : "primary";
    button.addEventListener("click", () => void grant(configDir));

    row.append(text, button);
    box.append(row);
  }
}

async function grant(configDir: string): Promise<void> {
  const status = byId("status");
  status.textContent = "";
  status.className = "muted";
  try {
    const handle = await configHandle(configDir, true);
    if (handle !== null) status.textContent = t("settingsSaved", `~/${configDir}`);
    await render();
  } catch (error) {
    if (error instanceof PickerError && error.kind !== "cancelled") {
      status.className = "error";
      status.textContent = t("pickerWrongFolder", error.chosen ?? "", `~/${configDir}`);
    }
  }
}

/** 隠しディレクトリはピッカーで見えない。開く前に OS 別の手順を出す。 */
byId("hint").textContent = (() => {
  const agent = navigator.userAgent;
  const key = agent.includes("Mac") ? "pickerIntroMac"
    : agent.includes("Windows") ? "pickerIntroWindows" : "pickerIntroLinux";
  return t(key, "~/.claude");
})();

void render();
