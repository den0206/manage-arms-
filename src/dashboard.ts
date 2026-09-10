import * as vscode from "vscode";
import { runCli } from "./cli";

export type DashboardItem = {
  name: string;
  kind: "skill" | "subagent" | "mcp" | "plugin";
  scope: "user" | "project";
  agents: string[];
  enabled: boolean;
  origin: "managed" | "user" | "bundled";
  sourcePath?: string;
  repoUrl?: string;
  hasUpdate: boolean;
};

export class DashboardProvider implements vscode.WebviewViewProvider, vscode.Disposable {
  private view?: vscode.WebviewView;
  private snapshot?: { at: number; items: DashboardItem[] };

  constructor(private readonly storagePath: string) {}
  dispose(): void { this.view = undefined; this.snapshot = undefined; }

  resolveWebviewView(view: vscode.WebviewView): void {
    this.view = view;
    view.webview.options = { enableScripts: true };
    view.webview.html = dashboardHtml(view.webview);
    view.webview.onDidReceiveMessage(message => {
      if (message?.type === "refresh") void this.refresh(true);
      if (message?.type === "addSkill") void vscode.commands.executeCommand("agent-tool.addSkill", typeof message.url === "string" ? message.url : undefined);
      if (message?.type === "addMcp") void vscode.commands.executeCommand("agent-tool.addMcp");
      if (message?.type === "actions" && isItem(message.item)) void vscode.commands.executeCommand("agent-tool.openToolActions", message.item);
    });
    view.onDidChangeVisibility(() => {
      if (view.visible) void this.refresh();
      else this.snapshot = undefined;
    });
    void this.refresh();
  }

  async refresh(force = false): Promise<void> {
    if (!this.view?.visible) return;
    if (!force && this.snapshot && Date.now() - this.snapshot.at < 180_000) {
      this.post(this.snapshot.items);
      return;
    }
    try {
      const result = await runCli("inventory", { storagePath: this.storagePath });
      const items = (result.data as { items?: DashboardItem[] } | undefined)?.items ?? [];
      this.snapshot = { at: Date.now(), items };
      this.post(items);
    } catch {
      this.post([]);
    }
  }

  private post(items: DashboardItem[]): void { this.view?.webview.postMessage({ type: "inventory", items }); }
}

function isItem(value: unknown): value is DashboardItem {
  return !!value && typeof value === "object" && typeof (value as DashboardItem).name === "string" && Array.isArray((value as DashboardItem).agents);
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
    .agent-nav { display:grid; gap:4px; margin:0 0 18px; } .agent { display:flex; align-items:center; justify-content:space-between; width:100%; color:var(--vscode-foreground); background:transparent; padding:8px 9px; text-align:left; }
    .agent:hover { background:var(--vscode-list-hoverBackground); } .agent.active { background:var(--vscode-list-activeSelectionBackground); color:var(--vscode-list-activeSelectionForeground); } .agent-count { opacity:.72; font-size:11px; }
    .bar { display:flex; gap:7px; align-items:center; margin:0 0 12px; } .bar button:first-child { margin-left:auto; } .add-form { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:6px; margin:0 0 14px; } input { min-width:0; color:var(--vscode-input-foreground); background:var(--vscode-input-background); border:1px solid var(--vscode-input-border); border-radius:6px; padding:7px 8px; font:inherit; }
    .filters { display:flex; gap:5px; overflow:auto; margin-bottom:12px; padding-bottom:2px; } .filter { white-space:nowrap; background:var(--vscode-editor-background); color:var(--vscode-foreground); border:1px solid var(--vscode-widget-border); padding:5px 8px; }
    .filter.active { color:var(--vscode-button-foreground); background:var(--vscode-button-background); border-color:var(--vscode-button-background); }
    .section { color:var(--vscode-descriptionForeground); font-size:11px; font-weight:600; letter-spacing:.4px; margin:17px 0 7px; text-transform:uppercase; }
    .list { display:grid; gap:6px; } .item { display:grid; grid-template-columns:27px minmax(0,1fr) auto; gap:9px; align-items:center; padding:9px; border:1px solid var(--vscode-widget-border); border-radius:8px; background:var(--vscode-editor-background); }
    .glyph { display:grid; place-items:center; width:27px; height:27px; border-radius:7px; background:color-mix(in srgb, var(--vscode-button-background) 20%, transparent); color:var(--vscode-textLink-foreground); font-size:14px; }
    .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:600; } .meta { color:var(--vscode-descriptionForeground); font-size:11px; margin-top:2px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .state { font-size:11px; color:var(--vscode-descriptionForeground); } .state.update { color:var(--vscode-editorWarning-foreground); } .state.off { opacity:.7; }
    .empty { color:var(--vscode-descriptionForeground); padding:28px 8px; text-align:center; } .hidden { display:none; }
  </style></head><body><header><div><h1>Agent Tool</h1><div class="sub">AI agent tools in this workspace</div></div><button class="icon" title="再読み込み" id="refresh">↻</button></header><div class="overview" id="overview"></div><div class="section">Add a Skill</div><form class="add-form" id="add-form"><input id="skill-url" type="url" maxlength="2048" required placeholder="https://github.com/owner/repository" aria-label="Public GitHub Skill URL"><button type="submit">Add</button></form><div class="section">AI Agents</div><nav class="agent-nav" id="agents"></nav><div class="bar"><strong id="inventory-title">All tools</strong><button id="skill">＋ Skill</button><button id="mcp">＋ MCP</button></div><div class="filters" id="filters"></div><div id="content"></div><script nonce="${nonce}">
  const vscode = acquireVsCodeApi(); let items = []; let agent = 'all'; let scope = 'all'; let kind = 'all';
  const kinds = {skill:'Skill',subagent:'Subagent',mcp:'MCP',plugin:'Plugin'}; const icons = {skill:'◇',subagent:'⌘',mcp:'◉',plugin:'▦'}; const agentNames = {claude:'Claude Code',cursor:'Cursor',codex:'Codex',gemini:'Gemini CLI'};
  const esc = s => String(s).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  function render() { const agents=['all',...Object.keys(agentNames).filter(a=>items.some(x=>x.agents.includes(a)))]; const visible=items.filter(x=>(agent==='all'||x.agents.includes(agent))&&(scope==='all'||x.scope===scope)&&(kind==='all'||x.kind===kind)); const managed=items.filter(x=>x.origin!=='bundled').length, updates=items.filter(x=>x.hasUpdate).length;
    document.querySelector('#overview').innerHTML='<div class="metric"><strong>'+managed+'</strong><span>Your tools</span></div><div class="metric"><strong>'+updates+'</strong><span>Updates available</span></div>';
    document.querySelector('#agents').innerHTML=agents.map(a=>'<button class="agent '+(a===agent?'active':'')+'" data-agent="'+a+'"><span>'+ (a==='all'?'All agents':agentNames[a]) +'</span><span class="agent-count">'+(a==='all'?items.length:items.filter(x=>x.agents.includes(a)).length)+'</span></button>').join(''); document.querySelector('#inventory-title').textContent=agent==='all'?'All tools':agentNames[agent];
    const filters=[['all','All'],['project','Current Project'],['user','User Global'],...Object.entries(kinds)]; document.querySelector('#filters').innerHTML=filters.map(([v,n])=>'<button class="filter '+((v===scope||v===kind)?'active':'')+'" data-filter="'+v+'">'+n+'</button>').join('');
    const rowsHtml=rows=>'<div class="list">'+rows.map(x=>'<div class="item"><div class="glyph">'+icons[x.kind]+'</div><div><div class="name">'+esc(x.name)+'</div><div class="meta">'+esc(x.agents.join(' · '))+' · '+kinds[x.kind]+'</div></div><button class="icon action" data-index="'+items.indexOf(x)+'" title="操作">•••</button></div>').join('')+'</div>'; const yours=visible.filter(x=>x.origin!=='bundled'); const yourGroups=Object.entries(kinds).map(([value,title])=>[title,yours.filter(x=>x.kind===value)]).filter(([,rows])=>rows.length); const bundled=visible.filter(x=>x.origin==='bundled'); document.querySelector('#content').innerHTML=visible.length?yourGroups.map(([title,rows])=>'<div class="section">Your tools · '+title+'</div>'+rowsHtml(rows)).join('')+(bundled.length?'<div class="section">Bundled</div>'+rowsHtml(bundled):''):'<div class="empty">この条件に一致するツールはありません。</div>';
    document.querySelectorAll('[data-agent]').forEach(b=>b.onclick=()=>{agent=b.dataset.agent; render();}); document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{const v=b.dataset.filter; if(v==='all'||v==='project'||v==='user') scope=v; else kind=v; render();}); document.querySelectorAll('.action').forEach(b=>b.onclick=()=>vscode.postMessage({type:'actions',item:items[Number(b.dataset.index)]})); }
  document.querySelector('#refresh').onclick=()=>vscode.postMessage({type:'refresh'}); document.querySelector('#add-form').onsubmit=e=>{e.preventDefault(); const input=document.querySelector('#skill-url'); vscode.postMessage({type:'addSkill',url:input.value}); input.value='';}; document.querySelector('#skill').onclick=()=>document.querySelector('#skill-url').focus(); document.querySelector('#mcp').onclick=()=>vscode.postMessage({type:'addMcp'}); window.addEventListener('message',e=>{if(e.data.type==='inventory'){items=e.data.items;render();}}); render();
  </script></body></html>`;
}
