// VS Code API をスタブして拡張の入口を検証する。Cursor を起動しないので全 OS で走る。
const { strict: assert } = require("node:assert");
const Module = require("node:module");
const { test } = require("node:test");
const { fakeEnv } = require("./helpers.js");

/** `require("vscode")` だけを差し替える。差し替えは 1 回の読み込みごとに戻す。 */
function loadExtension(stub, tool) {
  const load = Module._load;
  Module._load = (request, ...rest) => request === "vscode" ? stub
    : request === "./agentTool" && tool !== undefined ? tool : load(request, ...rest);
  try {
    delete require.cache[require.resolve("../out/extension.js")];
    delete require.cache[require.resolve("../out/dashboard.js")];
    return require("../out/extension.js");
  } finally {
    Module._load = load;
  }
}

function stubVscode(overrides = {}) {
  const state = {
    warnings: [], warningDetails: [], commands: new Map(), disposed: 0,
    provider: undefined, posted: [], picks: [],
  };
  const stub = {
    l10n: { t: (text, ...args) => args.reduce((acc, value, i) => acc.replace(`{${i}}`, value), text) },
    Uri: { joinPath: () => ({ fsPath: "" }) },
    ProgressLocation: { Notification: 15 },
    env: { remoteName: undefined },
    workspace: { isTrusted: true, workspaceFolders: undefined },
    window: {
      registerWebviewViewProvider: (_id, provider) => {
        state.provider = provider;
        return { dispose: () => { state.disposed += 1; } };
      },
      // モーダルの確認は最後の引数（操作ラベル）を押したことにする。
      showWarningMessage: (text, options, ...actions) => {
        state.warnings.push(text);
        state.warningDetails.push(options?.detail);
        const confirmed = options !== null && typeof options === "object" && options.modal === true;
        return Promise.resolve(confirmed ? actions[actions.length - 1] : undefined);
      },
      showInformationMessage: () => Promise.resolve(undefined),
      showInputBox: () => Promise.resolve(undefined),
      showQuickPick: items => { state.picks.push(items); return Promise.resolve(undefined); },
      withProgress: (_options, body) => body(),
    },
    commands: {
      registerCommand: (name, body) => { state.commands.set(name, body); return { dispose() {} }; },
      executeCommand: () => Promise.resolve(undefined),
    },
    ...overrides,
  };
  return { stub, state };
}

const activateWith = (stub, storagePath, tool) => {
  const extension = loadExtension(stub, tool);
  const context = {
    globalStorageUri: { fsPath: storagePath },
    extensionUri: { fsPath: "." },
    subscriptions: [],
    globalState: { get: () => undefined, update: async () => {} },
  };
  extension.activate(context);
  return { extension, context };
};

test("activate は CLI を起動せずに全コマンドを登録する", () => {
  const { stub, state } = stubVscode();
  activateWith(stub, fakeEnv().appSupport);
  for (const name of [
    "agent-tool.toggleTool", "agent-tool.addSkill", "agent-tool.addMcp", "agent-tool.removeTool",
    "agent-tool.previewUpdate", "agent-tool.applyUpdate", "agent-tool.refreshInventory",
    "agent-tool.openToolActions",
  ]) {
    assert.ok(state.commands.has(name), name);
  }
});

/** 未信頼ワークスペースでは一覧だけを許可する。 */
test("未信頼ワークスペースでは書き込みを拒否する", async () => {
  const { stub, state } = stubVscode({
    workspace: { isTrusted: false, workspaceFolders: undefined },
  });
  activateWith(stub, fakeEnv().appSupport);
  await state.commands.get("agent-tool.addSkill")();
  assert.equal(state.warnings.length, 1);
  assert.match(state.warnings[0], /trust this workspace/);
});

/** Remote 環境ではローカルの Agent 設定を書き換えない。 */
test("Remote 環境では書き込みを拒否する", async () => {
  const { stub, state } = stubVscode({ env: { remoteName: "ssh-remote" } });
  activateWith(stub, fakeEnv().appSupport);
  await state.commands.get("agent-tool.removeTool")({
    tool: { name: "x", kind: "skill", scope: "user", agents: ["claude"] },
    scope: "user",
    agent: "claude",
  });
  assert.equal(state.warnings.length, 1);
  assert.match(state.warnings[0], /local window/);
});

/**
 * Webview のスクリプトは tsc も node:test も構文を見ない。
 * 文言差し込みで壊れても気付けないので、ここで構文と文言表だけ確かめる。
 */
test("Webview の HTML は構文が通り、文言を l10n から引く", () => {
  const vm = require("node:vm");
  const { readFileSync } = require("node:fs");
  const bundle = JSON.parse(readFileSync(require.resolve("../l10n/bundle.l10n.json"), "utf8"));
  const { stub } = stubVscode({
    env: { remoteName: undefined, language: "en" },
    l10n: { t: text => bundle[text] ?? text },
  });
  const { DashboardProvider } = loadExtension(stub) && require("../out/dashboard.js");
  const provider = new DashboardProvider(fakeEnv().appSupport);
  let html = "";
  provider.resolveWebviewView({
    webview: {
      options: {}, cspSource: "vscode-resource:",
      set html(value) { html = value; },
      get html() { return html; },
      onDidReceiveMessage: () => ({ dispose() {} }),
      postMessage: () => Promise.resolve(true),
    },
    visible: false,
    onDidChangeVisibility: () => ({ dispose() {} }),
  });
  provider.dispose();

  const script = html.slice(html.lastIndexOf("<script"), html.lastIndexOf("</script>"));
  const body = script.slice(script.indexOf(">") + 1);
  new vm.Script(body);                                   // 構文エラーならここで落ちる
  assert.match(body, /const T = \{/);
  assert.equal(body.includes("</script"), false);        // 文言で閉じられていない
  assert.match(html, /No tools match this filter\./);    // 文言は l10n 由来
  assert.equal(/[\u3040-\u30ff]/.test(html), false);     // 既定言語に日本語が混ざらない
});

test("dispose でタイマーとキャッシュを手放す", () => {
  const { stub } = stubVscode();
  const { context } = activateWith(stub, fakeEnv().appSupport);
  for (const item of context.subscriptions) item.dispose?.();
  assert.ok(context.subscriptions.length > 0);
});

/** 表示中の Webview を用意して、一覧の再読み込みが届いたかを見る。 */
function showView(state) {
  state.provider.resolveWebviewView({
    webview: {
      options: {}, cspSource: "vscode-resource:", html: "",
      onDidReceiveMessage: () => ({ dispose() {} }),
      postMessage: message => { state.posted.push(message); return Promise.resolve(true); },
    },
    visible: true,
    onDidChangeVisibility: () => ({ dispose() {} }),
  });
}

/**
 * 削除や追加は `void` を返す。成否を戻り値の有無で判定すると、成功しても
 * `undefined` になって一覧が再読み込みされない（削除しても表が変わらない）。
 */
test("void を返す操作の成功後も一覧を読み直す", async () => {
  const { stub, state } = stubVscode();
  // 本体は走らせない。「成功して void を返した」状況だけを作る。
  stub.window.withProgress = () => Promise.resolve(undefined);
  const { context } = activateWith(stub, fakeEnv().appSupport, {
    inventory: async () => ({ items: [], issues: [] }), mcpStatus: async () => ({}),
  });
  try {
    showView(state);
    const before = state.posted.filter(message => message.type === "inventory").length;
    await state.commands.get("agent-tool.removeTool")({
      tool: { name: "x", kind: "skill", scope: "user", agents: ["claude"], origin: "user" },
      scope: "user",
      agent: "claude",
    });
    await new Promise(resolve => setImmediate(resolve));
    const after = state.posted.filter(message => message.type === "inventory").length;
    assert.ok(after > before, `再読み込みが走っていない (${before} → ${after})`);
  } finally {
    for (const item of context.subscriptions) item.dispose?.();
  }
});

test("Plugin の追加前に Marketplace を含むコマンドを表示する", async () => {
  const { stub, state } = stubVscode();
  stub.window.showQuickPick = items => { state.picks.push(items); return Promise.resolve("Claude Code"); };
  stub.window.withProgress = () => Promise.resolve(undefined);
  activateWith(stub, fakeEnv().appSupport);
  await state.commands.get("agent-tool.installPreview")({
    url: "https://github.com/acme/plugins", kind: "plugin", name: "tool", selector: "tool@market",
  });
  assert.equal(state.warningDetails.at(-1),
    "claude plugin marketplace add https://github.com/acme/plugins\nclaude plugin install tool@market -s user");
});

/** Plugin の削除はエージェントの CLI へ委譲する。操作一覧から落とすと到達できない。 */
test("Plugin にも削除の操作を出す", async () => {
  const { stub, state } = stubVscode();
  activateWith(stub, fakeEnv().appSupport);
  await state.commands.get("agent-tool.openToolActions")({
    name: "github@openai-curated-remote", kind: "plugin", scope: "user",
    agents: ["codex"], origin: "user", enabled: true, hasUpdate: false,
  });
  const labels = (state.picks[0] ?? []).map(action => action.label);
  assert.deepEqual(labels, ["Remove"]);
  assert.equal(state.warnings.length, 0);
});

/** 消してもエージェントの更新で戻るものには操作を出さない。 */
test("同梱プラグインには削除を出さない", async () => {
  const { stub, state } = stubVscode();
  activateWith(stub, fakeEnv().appSupport);
  await state.commands.get("agent-tool.openToolActions")({
    name: "openai-templates@openai-curated-remote", kind: "plugin", scope: "user",
    agents: ["codex"], origin: "bundled", enabled: true, hasUpdate: false,
  });
  assert.deepEqual(state.picks, []);
});
