import * as vscode from 'vscode';
import {runCli} from './cli';

export type DashboardItem = {
  name: string;
  kind: 'skill' | 'subagent' | 'mcp' | 'plugin';
  scope: 'user' | 'project';
  agents: string[];
  enabled: boolean;
  origin: 'managed' | 'user' | 'bundled';
  sourcePath?: string;
  repoUrl?: string;
  summary?: string;
  detail?: string;
  hasUpdate: boolean;
  running?: boolean;
};

export class DashboardProvider
  implements vscode.WebviewViewProvider, vscode.Disposable
{
  private view?: vscode.WebviewView;
  private snapshot?: {at: number; items: DashboardItem[]};
  private status = new Map<string, boolean>();
  private pollTimer?: NodeJS.Timeout;

  constructor(private readonly storagePath: string) {}
  dispose(): void {
    this.stopPoll();
    this.view = undefined;
    this.snapshot = undefined;
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
      else { this.stopPoll(); this.snapshot = undefined; }
    });
    void this.refresh();
    this.startPoll();
  }

  async refresh(force = false): Promise<void> {
    if (!this.view?.visible) return;
    if (!force && this.snapshot && Date.now() - this.snapshot.at < 180_000) {
      this.post(this.snapshot.items);
      return;
    }
    try {
      const result = await runCli('inventory', {storagePath: this.storagePath});
      const items =
        (result.data as {items?: DashboardItem[]} | undefined)?.items ?? [];
      this.snapshot = {at: Date.now(), items};
      this.post(items);
    } catch {
      this.post([]);
    }
  }

  private async openActions(item: DashboardItem): Promise<void> {
    const action = await vscode.window.showQuickPick(
      [
        {label: '説明・使用方法を表示', value: 'details'},
        {label: 'ツールを管理', value: 'manage'},
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
      const result = await runCli('preview', {storagePath: this.storagePath, url});
      const candidates = (result.data as {candidates?: unknown[]} | undefined)?.candidates ?? [];
      this.view?.webview.postMessage({type: 'preview', url, candidates});
    } catch (error) {
      this.view?.webview.postMessage({type: 'preview', url, candidates: [], error: error instanceof Error ? error.message : 'analysis failed'});
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
      const result = await runCli('mcp-status', {storagePath: this.storagePath});
      const servers = (result.data as {servers?: Array<{agent: string; name: string; running: boolean}>} | undefined)?.servers ?? [];
      this.status = new Map(servers.map(s => [`${s.agent}:${s.name}`, s.running]));
      if (this.snapshot) this.post(this.snapshot.items);
    } catch { /* keep previous status */ }
  }

  private post(items: DashboardItem[]): void {
    const annotated = items.map(item =>
      item.kind === 'mcp'
        ? {...item, running: item.agents.some(a => this.status.get(`${a}:${item.name}`) === true)}
        : item
    );
    this.view?.webview.postMessage({type: 'inventory', items: annotated});
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

function dashboardHtml(webview: vscode.Webview): string {
  const nonce = String(Date.now());
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}';"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    :root { color: var(--vscode-foreground); font-family: var(--vscode-font-family); font-size: 13px; }
    body { margin: 0; padding: 16px; background: var(--vscode-sideBar-background); }
    header { display:flex; align-items:center; justify-content:space-between; margin-bottom:20px; }
    h1 { margin:0; font-size:17px; letter-spacing:-.2px; } .sub { color:var(--vscode-descriptionForeground); margin-top:3px; font-size:12px; }
    button { border:0; color:var(--vscode-button-foreground); background:var(--vscode-button-background); border-radius:6px; padding:7px 9px; cursor:pointer; font:inherit; }
    button:hover { background:var(--vscode-button-hoverBackground); } button.icon { color:var(--vscode-foreground); background:transparent; font-size:16px; padding:5px 8px; }
    .overview { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px; margin-bottom:18px; }
    .metric { padding:11px; border:1px solid var(--vscode-widget-border); border-radius:8px; background:var(--vscode-editor-background); }
    .metric strong { display:block; font-size:21px; line-height:22px; } .metric span { color:var(--vscode-descriptionForeground); font-size:11px; }
    .agent-nav { display:flex; overflow-x:auto; margin:0 0 18px; border-bottom:1px solid var(--vscode-widget-border); } .agent { flex:0 0 auto; color:var(--vscode-foreground); background:transparent; border-radius:0; border-bottom:2px solid transparent; padding:8px 12px 7px; text-align:center; }
    .agent:hover { background:var(--vscode-list-hoverBackground); } .agent.active { color:var(--vscode-textLink-foreground); border-bottom-color:var(--vscode-textLink-foreground); } .agent-count { display:none; }
    .bar { display:flex; gap:7px; align-items:center; margin:0 0 12px; } .add-form { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:6px; margin:0 0 14px; } input { min-width:0; color:var(--vscode-input-foreground); background:var(--vscode-input-background); border:1px solid var(--vscode-input-border); border-radius:6px; padding:7px 8px; font:inherit; }
    .filters { display:flex; gap:5px; overflow:auto; margin-bottom:12px; padding-bottom:2px; } .filter { white-space:nowrap; background:var(--vscode-editor-background); color:var(--vscode-foreground); border:1px solid var(--vscode-widget-border); padding:5px 8px; }
    .filter.active { color:var(--vscode-button-foreground); background:var(--vscode-button-background); border-color:var(--vscode-button-background); }
    .section { color:var(--vscode-descriptionForeground); font-size:11px; font-weight:600; letter-spacing:.4px; margin:17px 0 7px; text-transform:uppercase; }
    .list { display:grid; gap:6px; } .item { display:grid; grid-template-columns:27px minmax(0,1fr) auto; gap:9px; align-items:center; padding:9px; border:1px solid var(--vscode-widget-border); border-radius:8px; background:var(--vscode-editor-background); }
    .glyph { display:grid; place-items:center; width:27px; height:27px; border-radius:7px; background:color-mix(in srgb, var(--vscode-button-background) 20%, transparent); color:var(--vscode-textLink-foreground); font-size:14px; }
    .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:600; } .meta { color:var(--vscode-descriptionForeground); font-size:11px; margin-top:2px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .state { font-size:11px; color:var(--vscode-descriptionForeground); } .state.update { color:var(--vscode-editorWarning-foreground); } .state.off { opacity:.7; }
    .empty { color:var(--vscode-descriptionForeground); padding:28px 8px; text-align:center; } .hidden { display:none; } .bundled-toggle { width:100%; color:var(--vscode-descriptionForeground); background:transparent; padding:3px 0; text-align:left; font-size:11px; font-weight:600; letter-spacing:.4px; text-transform:uppercase; } .detail { margin:0 0 16px; padding:11px; border:1px solid var(--vscode-widget-border); border-radius:8px; background:var(--vscode-editor-background); } .detail > .icon { float:right; } .detail h2 { margin:0 0 8px; font-size:14px; } .detail p { margin:7px 0; line-height:1.45; } .detail-label { color:var(--vscode-descriptionForeground); font-size:11px; font-weight:600; } .detail-path { font-family:var(--vscode-editor-font-family); font-size:11px; overflow-wrap:anywhere; } .loading { display:flex; align-items:center; gap:8px; color:var(--vscode-descriptionForeground); } .spinner { width:14px; height:14px; border:2px solid var(--vscode-widget-border); border-top-color:var(--vscode-textLink-foreground); border-radius:50%; animation:spin .8s linear infinite; } @keyframes spin { to { transform:rotate(360deg) } }
  </style></head><body><header><div><h1>Agent Tool</h1><div class="sub">AI agent tools in this workspace</div></div><button class="icon" title="再読み込み" id="refresh">↻</button></header><div class="overview" id="overview"></div><div class="section">ADD A Tool</div><form class="add-form" id="add-form"><input id="tool-url" type="url" maxlength="2048" required placeholder="https://github.com/owner/repository" aria-label="Public GitHub URL"><button type="submit">Analyze</button></form><section class="detail hidden" id="preview"></section><nav class="agent-nav" id="agents" aria-label="AI Agents"></nav><div class="bar"><strong id="inventory-title">All tools</strong></div><div class="filters" id="filters"></div><section class="detail hidden" id="detail"></section><div id="content"></div><script nonce="${nonce}">
  const vscode = acquireVsCodeApi(); let items = []; let agent = ''; let scope = 'project'; let bundledOpen = false; let selected = '';
  const kinds = {skill:'Skill',subagent:'Subagent',mcp:'MCP',plugin:'Plugin'}; const icons = {skill:'◇',subagent:'⌘',mcp:'◉',plugin:'▦'}; const agentNames = {claude:'Claude Code',cursor:'Cursor',codex:'Codex',gemini:'Gemini CLI'};
  const esc = s => String(s).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  function render() { const agents=Object.keys(agentNames); if(!agents.includes(agent)) agent=agents[0]; const visible=items.filter(x=>x.agents.includes(agent)&&x.scope===scope); const managed=items.filter(x=>x.origin!=='bundled').length, updates=items.filter(x=>x.hasUpdate).length;
    document.querySelector('#overview').innerHTML='<div class="metric"><strong>'+managed+'</strong><span>Your tools</span></div><div class="metric"><strong>'+updates+'</strong><span>Updates available</span></div>';
    document.querySelector('#agents').innerHTML=agents.map(a=>'<button class="agent '+(a===agent?'active':'')+'" data-agent="'+a+'" role="tab" aria-selected="'+(a===agent)+'"><span>'+agentNames[a]+'</span><span class="agent-count">'+items.filter(x=>x.agents.includes(a)).length+'</span></button>').join(''); document.querySelector('#inventory-title').textContent=agentNames[agent]||'Tools';
    const filters=[['project','Current Project'],['user','User Global']]; document.querySelector('#filters').innerHTML=filters.map(([v,n])=>'<button class="filter '+(v===scope?'active':'')+'" data-filter="'+v+'">'+n+'</button>').join('');
    const rowsHtml=rows=>'<div class="list">'+rows.map(x=>'<div class="item"><div class="glyph">'+icons[x.kind]+'</div><div><div class="name">'+esc(x.name)+'</div><div class="meta">'+esc(x.agents.join(' · '))+' · '+kinds[x.kind]+(x.kind==='mcp'?' · '+(x.running?'Running':'Stopped'):'')+'</div></div><button class="icon action" data-index="'+items.indexOf(x)+'" title="操作">•••</button></div>').join('')+'</div>'; const yours=visible.filter(x=>x.origin!=='bundled'); const yourGroups=Object.entries(kinds).map(([value,title])=>[title,yours.filter(x=>x.kind===value)]).filter(([,rows])=>rows.length); const bundled=visible.filter(x=>x.origin==='bundled'); document.querySelector('#content').innerHTML=visible.length?yourGroups.map(([title,rows])=>'<div class="section">Your tools · '+title+'</div>'+rowsHtml(rows)).join('')+(bundled.length?'<button class="bundled-toggle" id="bundled-toggle">Bundled · '+bundled.length+' '+(bundledOpen?'⌄':'›')+'</button>'+(bundledOpen?rowsHtml(bundled):''):''):'<div class="empty">この条件に一致するツールはありません。</div>';
    document.querySelectorAll('[data-agent]').forEach(b=>b.onclick=()=>{agent=b.dataset.agent; hideDetail(); render();}); document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{scope=b.dataset.filter; hideDetail(); render();}); document.querySelectorAll('.action').forEach(b=>b.onclick=e=>{e.stopPropagation(); vscode.postMessage({type:'actions',item:items[Number(b.dataset.index)]});}); const toggle=document.querySelector('#bundled-toggle'); if(toggle) toggle.onclick=()=>{bundledOpen=!bundledOpen; render();}; }
  function hideDetail() { selected=''; document.querySelector('#detail').classList.add('hidden'); }
  function showDetail(x) { const key=x.name+'|'+x.kind+'|'+x.scope; if(selected===key) { hideDetail(); return; } selected=key; const usage={skill:'チャットで名前を指定するか、内容に合う依頼をしてください。',subagent:'対応する Agent の委譲機能から指定して使います。',mcp:'対応する Agent の MCP ツールとして利用できます。',plugin:'対応する Agent の Plugin 機能から利用します。'}[x.kind]; const detail=document.querySelector('#detail'); detail.innerHTML='<button class="icon" id="close-detail" title="閉じる">×</button><h2>'+esc(x.name)+'</h2><div class="detail-label">DESCRIPTION</div><p>'+esc(x.summary||'説明は提供されていません。')+'</p><div class="detail-label">HOW TO USE</div><p>'+usage+'</p>'+(x.detail?'<div class="detail-label">LOCATION</div><p class="detail-path">'+esc(x.detail)+'</p>':'')+(x.repoUrl?'<div class="detail-label">SOURCE</div><p class="detail-path">'+esc(x.repoUrl)+'</p>':''); detail.classList.remove('hidden'); document.querySelector('#close-detail').onclick=hideDetail; detail.scrollIntoView({block:'nearest'}); }
  function hidePreview() { document.querySelector('#preview').classList.add('hidden'); }
  function showPreview(result) { const panel=document.querySelector('#preview'); const rows=result.candidates||[]; const body=result.loading?'<div class="loading"><span class="spinner"></span>Analyzing URL…</div>':rows.length?'<h2>検知したツール</h2>'+rows.map((x,i)=>'<p><strong>'+esc(x.installSelector||x.name)+'</strong> · '+esc(kinds[x.kind]||x.kind)+'<br>'+esc(x.description||'説明は提供されていません。')+'<br><button class="install" data-index="'+i+'">導入するツールを追加</button></p>').join(''):'<h2>ツールが見つかりません</h2><p>'+esc(result.error||'このURLには対応するSkill、MCP、Plugin、Sub Agentが見つかりません。')+'</p>'; panel.innerHTML='<button class="icon" id="close-preview" title="閉じる">×</button>'+body; panel.classList.remove('hidden'); document.querySelector('#close-preview').onclick=hidePreview; panel.querySelectorAll('.install').forEach(b=>b.onclick=()=>{b.disabled=true; b.textContent='Installing…'; const candidate=rows[Number(b.dataset.index)]; vscode.postMessage({type:'installTool',url:result.url,kind:candidate.kind,name:candidate.name,selector:candidate.installSelector});}); }
  document.querySelector('#refresh').onclick=()=>vscode.postMessage({type:'refresh'}); document.querySelector('#add-form').onsubmit=e=>{e.preventDefault(); vscode.postMessage({type:'analyzeTool',url:document.querySelector('#tool-url').value});}; window.addEventListener('message',e=>{if(e.data.type==='inventory'){items=e.data.items;render();} if(e.data.type==='details') showDetail(e.data.item); if(e.data.type==='analysisStart') showPreview(e.data); if(e.data.type==='preview') showPreview(e.data);}); render();
  </script></body></html>`;
}
