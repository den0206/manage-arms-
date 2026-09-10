import * as vscode from 'vscode';
import * as agentTool from './agentTool';

export type DashboardItem = {
  name: string;
  kind: 'skill' | 'subagent' | 'mcp' | 'plugin';
  scope: 'user' | 'project';
  agents: string[];
  enabled: boolean;
  origin: 'managed' | 'user' | 'bundled';
  sourcePath?: string;
  pluginScope?: 'user' | 'project' | 'local';
  repoUrl?: string;
  summary?: string;
  detail?: string;
  hasUpdate: boolean;
  running?: boolean;
  /** MCP の登録先。削除コマンドの `-s` に載る。 */
  mcpScope?: 'user' | 'project' | 'local';
};

export class DashboardProvider
  implements vscode.WebviewViewProvider, vscode.Disposable
{
  private view?: vscode.WebviewView;
  private snapshot?: {at: number; items: DashboardItem[]};
  private status = new Map<string, boolean>();
  private issues: string[] = [];
  private pollTimer?: NodeJS.Timeout;

  constructor(private readonly storagePath: string) {}
  dispose(): void {
    this.stopPoll();
    this.view = undefined;
    this.snapshot = undefined;
    this.issues = [];
  }

  resolveWebviewView(view: vscode.WebviewView): void {
    this.view = view;
    view.webview.options = {enableScripts: true};
    view.webview.html = dashboardHtml(view.webview);
    view.webview.onDidReceiveMessage((message) => {
      if (message?.type === 'refresh') void this.refresh(true);
      if (message?.type === 'addSkill')
        void vscode.commands.executeCommand(
          'agent-tool.addSkill',
          typeof message.url === 'string' ? message.url : undefined,
        );
      if (message?.type === 'analyzeTool' && typeof message.url === 'string')
        void this.analyze(message.url);
      if (message?.type === 'installTool' && typeof message.url === 'string' && typeof message.kind === 'string')
        void vscode.commands.executeCommand('agent-tool.installPreview', message);
      if (message?.type === 'addMcp')
        void vscode.commands.executeCommand('agent-tool.addMcp');
      if (message?.type === 'actions' && isItem(message.item))
        void this.openActions(message.item);
    });
    view.onDidChangeVisibility(() => {
      if (view.visible) { void this.refresh(); this.startPoll(); }
      else { this.stopPoll(); this.snapshot = undefined; this.issues = []; }
    });
    if (view.visible) { void this.refresh(); this.startPoll(); }
  }

  async refresh(force = false): Promise<void> {
    if (!this.view?.visible) return;
    if (!force && this.snapshot && Date.now() - this.snapshot.at < 180_000) {
      this.post(this.snapshot.items, this.issues);
      return;
    }
    try {
      const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? null;
      const {items, issues} = await agentTool.inventory({
        storagePath: this.storagePath,
        projectPath: folder,
      });
      this.snapshot = {at: Date.now(), items: items as DashboardItem[]};
      // 走査に失敗したエージェントは黙って 0 件にしない。「未検出」と
      // 「読めなかった」が同じ見た目になると、消してよいものが判断できない。
      this.post(this.snapshot.items, issues);
    } catch (error) {
      this.post([], [], error instanceof Error ? error.message : String(error));
    }
  }

  private async openActions(item: DashboardItem): Promise<void> {
    const action = await vscode.window.showQuickPick(
      [
        {label: vscode.l10n.t('Show description and usage'), value: 'details'},
        {label: vscode.l10n.t('Manage this tool'), value: 'manage'},
      ],
      {placeHolder: item.name},
    );
    if (action?.value === 'details')
      this.view?.webview.postMessage({type: 'details', item});
    if (action?.value === 'manage')
      void vscode.commands.executeCommand('agent-tool.openToolActions', item);
  }

  private async analyze(url: string): Promise<void> {
    this.view?.webview.postMessage({type: 'analysisStart', loading: true});
    try {
      const candidates = await agentTool.preview({url});
      this.view?.webview.postMessage({type: 'preview', url, candidates});
    } catch (error) {
      this.view?.webview.postMessage({type: 'preview', url, candidates: [],
        error: error instanceof Error ? error.message : vscode.l10n.t('The URL could not be analyzed.')});
    }
  }

  private startPoll(): void {
    this.stopPoll();
    void this.refreshStatus();
    this.pollTimer = setInterval(() => void this.refreshStatus(), 3_000);
  }

  private stopPoll(): void {
    if (this.pollTimer) { clearInterval(this.pollTimer); this.pollTimer = undefined; }
    this.status.clear();
  }

  private async refreshStatus(): Promise<void> {
    if (!this.view?.visible) return;
    try {
      const status = await agentTool.mcpStatus({storagePath: this.storagePath});
      this.status = new Map(Object.entries(status));
      if (this.snapshot) this.post(this.snapshot.items, this.issues);
    } catch { /* keep previous status */ }
  }

  private post(items: DashboardItem[], issues: string[] = [], error?: string): void {
    this.issues = issues;
    const annotated = items.map(item =>
      item.kind === 'mcp'
        ? {...item, running: item.agents.some(a => this.status.get(`${a}:${item.name}`) === true)}
        : item
    );
    const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    const projectName = folder === undefined
      ? 'Current Project'
      : folder.split(/[\\/]/).filter(Boolean).pop() ?? 'Current Project';
    this.view?.webview.postMessage({type: 'inventory', items: annotated, projectName, issues, error});
  }
}

function isItem(value: unknown): value is DashboardItem {
  return (
    !!value &&
    typeof value === 'object' &&
    typeof (value as DashboardItem).name === 'string' &&
    Array.isArray((value as DashboardItem).agents)
  );
}

/**
 * Webview の文言。`vscode.l10n.t` は拡張ホストでしか使えないので、
 * ここで引き当ててからスクリプトへ渡す（不変条件 6: en / ja を同時に持つ）。
 */
const webviewText = (): Record<string, string> => ({
  title: vscode.l10n.t("Agent Tool"),
  subtitle: vscode.l10n.t("AI agent tools in this workspace"),
  refresh: vscode.l10n.t("Refresh"),
  close: vscode.l10n.t("Close"),
  actions: vscode.l10n.t("Actions"),
  addSection: vscode.l10n.t("Add a tool"),
  analyze: vscode.l10n.t("Analyze"),
  analyzing: vscode.l10n.t("Analyzing URL…"),
  urlLabel: vscode.l10n.t("Public GitHub URL"),
  yourTools: vscode.l10n.t("Your tools"),
  updates: vscode.l10n.t("Updates available"),
  userGlobal: vscode.l10n.t("User Global"),
  bundled: vscode.l10n.t("Bundled"),
  showLess: vscode.l10n.t("Show less"),
  running: vscode.l10n.t("Running"),
  stopped: vscode.l10n.t("Stopped"),
  noAgents: vscode.l10n.t("No tools are installed for any AI agent. Add one from the URL field above."),
  noMatch: vscode.l10n.t("No tools match this filter."),
  detected: vscode.l10n.t("Detected tools"),
  notFound: vscode.l10n.t("No tools were found"),
  notFoundBody: vscode.l10n.t("This URL has no Skill, MCP, Plugin, or Subagent that Agent Tool can install."),
  install: vscode.l10n.t("Install this tool"),
  installing: vscode.l10n.t("Installing…"),
  noDescription: vscode.l10n.t("No description was provided."),
  description: vscode.l10n.t("Description"),
  howToUse: vscode.l10n.t("How to use"),
  location: vscode.l10n.t("Location"),
  source: vscode.l10n.t("Source"),
  loadFailed: vscode.l10n.t("The tool list could not be read; it may be incomplete."),
  useSkill: vscode.l10n.t("Name it in chat, or ask for something it covers."),
  useSubagent: vscode.l10n.t("Delegate to it from the agent's subagent feature."),
  useMcp: vscode.l10n.t("Available as an MCP tool in the matching agent."),
  usePlugin: vscode.l10n.t("Use it from the matching agent's plugin feature."),
});

function dashboardHtml(webview: vscode.Webview): string {
  const nonce = String(Date.now());
  // `</script>` で閉じられないよう `<` を退避してから埋め込む。
  const text0 = webviewText();
  const text = JSON.stringify(text0).replace(/</g, "\\u003c");
  return `<!doctype html><html lang="${(vscode.env.language ?? "").startsWith("ja") ? "ja" : "en"}"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}';"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    :root { color: var(--vscode-foreground); font-family: var(--vscode-font-family); font-size: 13px; }
    body { margin: 0; padding: 16px; background: var(--vscode-sideBar-background); }
    header { display:flex; align-items:center; justify-content:space-between; margin-bottom:20px; }
    h1 { margin:0; font-size:17px; letter-spacing:-.2px; } .sub { color:var(--vscode-descriptionForeground); margin-top:3px; font-size:12px; }
    button { border:0; color:var(--vscode-button-foreground); background:var(--vscode-button-background); border-radius:6px; padding:7px 9px; cursor:pointer; font:inherit; }
    button:hover { background:var(--vscode-button-hoverBackground); } button.icon { color:var(--vscode-foreground); background:transparent; font-size:16px; padding:5px 8px; }
    .overview { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px; margin-bottom:18px; }
    .metric { padding:11px; border:1px solid var(--vscode-widget-border); border-radius:8px; background:var(--vscode-editor-background); }
    .metric strong { display:block; font-size:21px; line-height:22px; } .metric span { color:var(--vscode-descriptionForeground); font-size:11px; }
    .agent-nav { display:flex; overflow-x:auto; margin:0 0 18px; border-bottom:1px solid var(--vscode-widget-border); } .agent { flex:0 0 auto; display:flex; align-items:center; gap:5px; color:var(--vscode-foreground); background:transparent; border-radius:0; border-bottom:2px solid transparent; padding:8px 12px 7px; }
    .agent:hover { background:var(--vscode-list-hoverBackground); } .agent.active { color:var(--vscode-textLink-foreground); border-bottom-color:var(--vscode-textLink-foreground); } .agent-count { display:none; }
    .bar { display:flex; gap:7px; align-items:center; margin:0 0 12px; } .add-form { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:6px; margin:0 0 14px; } input { min-width:0; color:var(--vscode-input-foreground); background:var(--vscode-input-background); border:1px solid var(--vscode-input-border); border-radius:6px; padding:7px 8px; font:inherit; }
    .filters { display:flex; gap:5px; overflow:auto; margin-bottom:12px; padding-bottom:2px; } .filter { white-space:nowrap; background:var(--vscode-editor-background); color:var(--vscode-foreground); border:1px solid var(--vscode-widget-border); padding:5px 8px; }
    .filter.active { color:var(--vscode-button-foreground); background:var(--vscode-button-background); border-color:var(--vscode-button-background); }
    .section { color:var(--vscode-foreground); font-size:12px; font-weight:700; letter-spacing:.3px; margin:20px 0 8px; padding:0 0 6px; border-bottom:1px solid var(--vscode-widget-border); text-transform:uppercase; }
    .list { display:grid; gap:6px; } .item { display:grid; grid-template-columns:27px minmax(0,1fr) auto; gap:9px; align-items:center; padding:9px; border:1px solid var(--vscode-widget-border); border-radius:8px; background:var(--vscode-editor-background); }
    .glyph { display:grid; place-items:center; width:27px; height:27px; border-radius:7px; background:color-mix(in srgb, var(--vscode-button-background) 20%, transparent); color:var(--vscode-textLink-foreground); font-size:14px; }
    .glyph[data-kind="skill"]    { background:color-mix(in srgb,var(--vscode-charts-orange,#d97706) 15%,transparent); color:var(--vscode-charts-orange,#d97706); }
    .glyph[data-kind="subagent"] { background:color-mix(in srgb,var(--vscode-charts-blue,#3b82f6) 15%,transparent); color:var(--vscode-charts-blue,#3b82f6); }
    .glyph[data-kind="mcp"]      { background:color-mix(in srgb,var(--vscode-charts-green,#22c55e) 15%,transparent); color:var(--vscode-charts-green,#22c55e); }
    .glyph[data-kind="plugin"]   { background:color-mix(in srgb,var(--vscode-charts-purple,#8b5cf6) 15%,transparent); color:var(--vscode-charts-purple,#8b5cf6); }
    .agent-dot { width:6px; height:6px; border-radius:50%; background:var(--vscode-descriptionForeground); opacity:.3; flex-shrink:0; }
    .agent.active .agent-dot { opacity:1; }
    .agent[data-agent="claude"] .agent-dot { background:var(--vscode-charts-orange,#d97706); }
    .agent[data-agent="cursor"] .agent-dot { background:var(--vscode-charts-blue,#3b82f6); }
    .agent[data-agent="codex"]  .agent-dot { background:var(--vscode-charts-green,#22c55e); }
    .agent[data-agent="gemini"] .agent-dot { background:var(--vscode-charts-purple,#8b5cf6); }
    .agent-badge { display:flex; align-items:center; gap:10px; padding:9px 11px; margin:0 0 12px; border-radius:8px; background:var(--vscode-editor-background); border:1px solid var(--vscode-widget-border); }
    .badge-pip { width:10px; height:10px; border-radius:50%; flex-shrink:0; }
    .badge-pip[data-agent="claude"] { background:var(--vscode-charts-orange,#d97706); }
    .badge-pip[data-agent="cursor"] { background:var(--vscode-charts-blue,#3b82f6); }
    .badge-pip[data-agent="codex"]  { background:var(--vscode-charts-green,#22c55e); }
    .badge-pip[data-agent="gemini"] { background:var(--vscode-charts-purple,#8b5cf6); }
    .badge-name { font-weight:700; font-size:13px; }
    .badge-count { color:var(--vscode-descriptionForeground); font-size:11px; margin-left:auto; }
    .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:600; } .meta { color:var(--vscode-descriptionForeground); font-size:11px; margin-top:2px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .state { font-size:11px; color:var(--vscode-descriptionForeground); } .state.update { color:var(--vscode-editorWarning-foreground); } .state.off { opacity:.7; }
    .empty { color:var(--vscode-descriptionForeground); padding:28px 8px; text-align:center; } .hidden { display:none; } .bundled-toggle { width:100%; color:var(--vscode-descriptionForeground); background:transparent; padding:3px 0; text-align:left; font-size:11px; font-weight:600; letter-spacing:.4px; text-transform:uppercase; } .section-toggle { width:100%; color:var(--vscode-descriptionForeground); background:transparent; border:1px solid var(--vscode-widget-border); border-top:none; border-radius:0 0 8px 8px; padding:6px 0; font-size:11px; font-weight:600; text-align:center; margin-bottom:6px; } .detail { margin:0 0 16px; padding:11px; border:1px solid var(--vscode-widget-border); border-radius:8px; background:var(--vscode-editor-background); } .detail > .icon { float:right; } .detail h2 { margin:0 0 8px; font-size:14px; } .detail p { margin:7px 0; line-height:1.45; } .detail-label { color:var(--vscode-descriptionForeground); font-size:11px; font-weight:600; } .detail-path { font-family:var(--vscode-editor-font-family); font-size:11px; overflow-wrap:anywhere; } .issues { grid-column:1/-1; border-color:var(--vscode-editorWarning-foreground); } .issues strong { color:var(--vscode-editorWarning-foreground); font-size:15px; } .loading { display:flex; align-items:center; gap:8px; color:var(--vscode-descriptionForeground); } .spinner { width:14px; height:14px; border:2px solid var(--vscode-widget-border); border-top-color:var(--vscode-textLink-foreground); border-radius:50%; animation:spin .8s linear infinite; } @keyframes spin { to { transform:rotate(360deg) } }
  </style></head><body><header><div><h1>Agent Tool</h1><div class="sub">${text0.subtitle}</div></div><button class="icon" title="${text0.refresh}" id="refresh">↻</button></header><div class="overview" id="overview"></div><div class="section">${text0.addSection}</div><form class="add-form" id="add-form"><input id="tool-url" type="url" maxlength="2048" required placeholder="https://github.com/owner/repository" aria-label="${text0.urlLabel}"><button type="submit">${text0.analyze}</button></form><section class="detail hidden" id="preview"></section><nav class="agent-nav" id="agents" aria-label="AI Agents"></nav><div class="agent-badge" id="agent-badge"></div><div class="filters" id="filters"></div><section class="detail hidden" id="detail"></section><div id="content"></div><script nonce="${nonce}">
  const vscode = acquireVsCodeApi(); const T = ${text}; let items = []; let issues = []; let loadError = ''; let agent = ''; let scope = 'project'; let projectName = 'Current Project'; let sectionExpanded = {}; let selected = '';
  const kinds = {skill:'Skill',subagent:'Subagent',mcp:'MCP',plugin:'Plugin'}; const icons = {skill:'<svg viewBox="0 0 14 14" width="13" height="13" fill="currentColor"><path d="M2 0h10v14H2V0zm2 3h6v1.5H4V3zm0 3h6v1.5H4V6zm0 3h4v1.5H4V9z"/></svg>',subagent:'<svg viewBox="0 0 14 14" width="13" height="13" fill="currentColor"><circle cx="7" cy="4" r="3"/><path d="M1 13.5c0-3.3 2.7-6 6-6s6 2.7 6 6H1z"/></svg>',mcp:'<svg viewBox="0 0 14 14" width="13" height="13" fill="currentColor"><rect x="1" y="0" width="12" height="5" rx="1.5"/><rect x="1" y="7" width="12" height="5" rx="1.5"/></svg>',plugin:'<svg viewBox="0 0 14 14" width="13" height="13" fill="currentColor"><path d="M5 0h1.5v3H5zm3.5 0H10v3H8.5zM2.5 3h9v2.5a4.5 4.5 0 01-3.5 4.4V14h-2v-3.6A4.5 4.5 0 012.5 5.5V3z"/></svg>'}; const agentNames = {claude:'Claude Code',cursor:'Cursor',codex:'Codex',gemini:'Gemini CLI'};
  const esc = s => String(s).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  function render() { const agents=Object.keys(agentNames).filter(a=>items.some(x=>x.agents.includes(a))); if(!agents.includes(agent)) agent=agents[0]??''; const visible=items.filter(x=>x.agents.includes(agent)&&x.scope===scope); const managed=items.filter(x=>x.origin!=='bundled').length, updates=items.filter(x=>x.hasUpdate).length;
    document.querySelector('#overview').innerHTML='<div class="metric"><strong>'+managed+'</strong><span>'+esc(T.yourTools)+'</span></div><div class="metric"><strong>'+updates+'</strong><span>'+esc(T.updates)+'</span></div>'+banner();
    document.querySelector('#agents').innerHTML=agents.length?agents.map(a=>'<button class="agent '+(a===agent?'active':'')+'" data-agent="'+a+'" role="tab" aria-selected="'+(a===agent)+'"><span class="agent-dot"></span><span>'+agentNames[a]+'</span><span class="agent-count">'+items.filter(x=>x.agents.includes(a)).length+'</span></button>').join(''):'<p class="empty">'+esc(T.noAgents)+'</p>'; const _cnt=items.filter(x=>x.agents.includes(agent)).length;const _ab=document.querySelector('#agent-badge');if(_ab)_ab.innerHTML=agent?'<span class="badge-pip" data-agent="'+agent+'"></span><span class="badge-name">'+agentNames[agent]+'</span><span class="badge-count">'+_cnt+' tool'+(_cnt===1?'':'s')+'</span>':'';
    const filters=[['user',T.userGlobal],['project',projectName]]; document.querySelector('#filters').innerHTML=filters.map(([v,n])=>'<button class="filter '+(v===scope?'active':'')+'" data-filter="'+v+'">'+n+'</button>').join('');
    const rowsHtml=rows=>'<div class="list">'+rows.map(x=>'<div class="item"><div class="glyph" data-kind="'+x.kind+'">'+icons[x.kind]+'</div><div><div class="name">'+esc(x.name)+'</div><div class="meta">'+esc(x.agents.join(' · '))+' · '+kinds[x.kind]+(x.kind==='mcp'?' · '+esc(x.running?T.running:T.stopped):'')+'</div></div><button class="icon action" data-index="'+items.indexOf(x)+'" title="'+esc(T.actions)+'">•••</button></div>').join('')+'</div>'; const yours=visible.filter(x=>x.origin!=='bundled'); const yourGroups=Object.entries(kinds).map(([value,title])=>[title,yours.filter(x=>x.kind===value),value]).filter(([,rows])=>rows.length); const bundled=visible.filter(x=>x.origin==='bundled'); document.querySelector('#content').innerHTML=visible.length?yourGroups.map(([title,rows,kv])=>{const exp=sectionExpanded[kv]; const shown=exp?rows:rows.slice(0,5); const rest=rows.length-shown.length; const tog=rows.length>5?'<button class="section-toggle" data-kind="'+kv+'">'+(exp?'⏄ '+esc(T.showLess):'› '+rest+' more')+'</button>':''; return '<div class="section">'+title+'</div>'+rowsHtml(shown)+tog;}).join('')+(bundled.length?(()=>{const exp=sectionExpanded['bundled']; const shown=exp?bundled:[]; const rest=bundled.length; const tog='<button class="section-toggle" data-kind="bundled">'+(exp?'⏄ '+esc(T.showLess):'› '+rest+' more')+'</button>'; return '<div class="section">'+esc(T.bundled)+'</div>'+rowsHtml(shown)+tog;})():''):'<div class="empty">'+esc(T.noMatch)+'</div>';
    document.querySelectorAll('[data-agent]').forEach(b=>b.onclick=()=>{agent=b.dataset.agent; hideDetail(); render();}); document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{scope=b.dataset.filter; hideDetail(); render();}); document.querySelectorAll('.action').forEach(b=>b.onclick=e=>{e.stopPropagation(); vscode.postMessage({type:'actions',item:items[Number(b.dataset.index)]});}); document.querySelectorAll('.section-toggle').forEach(b=>b.onclick=()=>{sectionExpanded[b.dataset.kind]=!sectionExpanded[b.dataset.kind]; render();}); }
  function banner() { const lines=(loadError?[loadError]:[]).concat(issues); return lines.length?'<div class="metric issues"><strong>⚠</strong><span>'+esc(T.loadFailed)+'<br>'+lines.map(esc).join('<br>')+'</span></div>':''; }
  function hideDetail() { selected=''; document.querySelector('#detail').classList.add('hidden'); }
  function showDetail(x) { const key=x.name+'|'+x.kind+'|'+x.scope; if(selected===key) { hideDetail(); return; } selected=key; const usage=esc({skill:T.useSkill,subagent:T.useSubagent,mcp:T.useMcp,plugin:T.usePlugin}[x.kind]||''); const detail=document.querySelector('#detail'); detail.innerHTML='<button class="icon" id="close-detail" title="'+esc(T.close)+'">×</button><h2>'+esc(x.name)+'</h2><div class="detail-label">'+esc(T.description)+'</div><p>'+esc(x.summary||T.noDescription)+'</p><div class="detail-label">'+esc(T.howToUse)+'</div><p>'+usage+'</p>'+(x.detail?'<div class="detail-label">'+esc(T.location)+'</div><p class="detail-path">'+esc(x.detail)+'</p>':'')+(x.repoUrl?'<div class="detail-label">'+esc(T.source)+'</div><p class="detail-path">'+esc(x.repoUrl)+'</p>':''); detail.classList.remove('hidden'); document.querySelector('#close-detail').onclick=hideDetail; detail.scrollIntoView({block:'nearest'}); }
  function hidePreview() { document.querySelector('#preview').classList.add('hidden'); }
  function showPreview(result) { const panel=document.querySelector('#preview'); const rows=result.candidates||[]; const body=result.loading?'<div class="loading"><span class="spinner"></span>'+esc(T.analyzing)+'</div>':rows.length?'<h2>'+esc(T.detected)+'</h2>'+rows.map((x,i)=>'<p><strong>'+esc(x.installSelector||x.name)+'</strong> · '+esc(kinds[x.kind]||x.kind)+'<br>'+esc(x.description||T.noDescription)+'<br><button class="install" data-index="'+i+'">'+esc(T.install)+'</button></p>').join(''):'<h2>'+esc(T.notFound)+'</h2><p>'+esc(result.error||T.notFoundBody)+'</p>'; panel.innerHTML='<button class="icon" id="close-preview" title="'+esc(T.close)+'">×</button>'+body; panel.classList.remove('hidden'); document.querySelector('#close-preview').onclick=hidePreview; panel.querySelectorAll('.install').forEach(b=>b.onclick=()=>{b.disabled=true; b.textContent=T.installing; const candidate=rows[Number(b.dataset.index)]; vscode.postMessage({type:'installTool',url:result.url,kind:candidate.kind,name:candidate.name,selector:candidate.installSelector});}); }
  document.querySelector('#refresh').onclick=()=>vscode.postMessage({type:'refresh'}); document.querySelector('#add-form').onsubmit=e=>{e.preventDefault(); vscode.postMessage({type:'analyzeTool',url:document.querySelector('#tool-url').value});}; window.addEventListener('message',e=>{if(e.data.type==='inventory'){items=e.data.items; issues=e.data.issues||[]; loadError=e.data.error||''; if(e.data.projectName) projectName=e.data.projectName; render();} if(e.data.type==='details') showDetail(e.data.item); if(e.data.type==='analysisStart') showPreview(e.data); if(e.data.type==='preview') showPreview(e.data);}); render();
  </script></body></html>`;
}
