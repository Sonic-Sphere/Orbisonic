import Foundation

// Server-rendered web control surface for Orbisonic. The control token is
// injected directly into the page so the LAN UI works with no login friction
// (auth is deferred). Offline-safe: no CDN fonts or external assets, since the
// sphere typically runs on an isolated network.
extension OrbisonicWebServer {
    static func controlPageHTML(token: String) -> String {
        return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#04070d">
<title>Orbisonic · Mission Control</title>
<style>
:root{
  --bg:#04070d;
  --bg2:#070d18;
  --panel:rgba(16,26,42,0.66);
  --panel-solid:#0c1525;
  --edge:rgba(120,200,255,0.14);
  --edge-strong:rgba(120,200,255,0.30);
  --text:#e8f2ff;
  --muted:#7c8ea6;
  --dim:#54647c;
  --accent:#38e1ff;
  --accent2:#27ffc2;
  --amber:#ffb454;
  --red:#ff5d72;
  --glow:rgba(56,225,255,0.45);
  --display:"Futura","Avenir Next","Avenir","Segoe UI",system-ui,sans-serif;
  --body:"Avenir Next","Avenir",-apple-system,"Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{
  font-family:var(--body);
  color:var(--text);
  background:
    radial-gradient(1200px 800px at 78% -8%,rgba(39,255,194,0.10),transparent 55%),
    radial-gradient(1100px 760px at 12% 4%,rgba(56,225,255,0.14),transparent 52%),
    linear-gradient(180deg,var(--bg2),var(--bg) 60%);
  background-attachment:fixed;
  min-height:100%;
  letter-spacing:0.01em;
  -webkit-font-smoothing:antialiased;
  padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
}
.shell{max-width:1080px;margin:0 auto;padding:22px 18px 64px}
/* Header */
header{
  display:flex;align-items:center;gap:16px;
  padding:6px 4px 22px;
}
.orb{
  position:relative;width:46px;height:46px;flex:0 0 auto;border-radius:50%;
  background:radial-gradient(circle at 32% 30%,#0bd,#063b52 60%,#021824);
  box-shadow:0 0 0 1px var(--edge-strong),0 0 26px var(--glow);
}
.orb::before,.orb::after{
  content:"";position:absolute;inset:6px;border-radius:50%;
  border:1px solid rgba(190,240,255,0.45);
  transform:rotate(28deg) scaleY(0.42);
}
.orb::after{transform:rotate(-28deg) scaleY(0.42);border-color:rgba(39,255,194,0.5)}
.brand h1{
  font-family:var(--display);font-weight:600;font-size:21px;letter-spacing:0.22em;
  text-transform:uppercase;
}
.brand .sub{color:var(--muted);font-size:11px;letter-spacing:0.34em;text-transform:uppercase;margin-top:3px}
.status-pill{
  margin-left:auto;display:flex;align-items:center;gap:8px;
  font-size:11px;letter-spacing:0.18em;text-transform:uppercase;color:var(--muted);
  padding:8px 14px;border-radius:999px;border:1px solid var(--edge);
  background:rgba(10,18,30,0.55);
}
.dot{width:8px;height:8px;border-radius:50%;background:var(--dim);transition:background .3s,box-shadow .3s}
.live .dot{background:var(--accent2);box-shadow:0 0 10px var(--accent2)}
.stale .dot{background:var(--amber);box-shadow:0 0 10px var(--amber)}
/* Layout */
.grid{display:grid;grid-template-columns:1fr;gap:18px}
.col{display:flex;flex-direction:column;gap:18px}
@media(min-width:900px){
  .grid{grid-template-columns:1.05fr 0.95fr;align-items:start}
}
/* Panels */
.panel{
  position:relative;border-radius:20px;padding:20px;
  background:var(--panel);
  border:1px solid var(--edge);
  backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
  box-shadow:0 18px 50px rgba(0,0,0,0.42),inset 0 1px 0 rgba(255,255,255,0.04);
}
.panel h2{
  font-family:var(--display);font-size:12px;font-weight:600;letter-spacing:0.26em;
  text-transform:uppercase;color:var(--accent);margin-bottom:16px;
  display:flex;align-items:center;gap:10px;
}
.panel h2::after{content:"";flex:1;height:1px;background:linear-gradient(90deg,var(--edge-strong),transparent)}
/* Now playing */
.np{display:flex;gap:18px;align-items:center}
.art{
  width:104px;height:104px;flex:0 0 auto;border-radius:16px;overflow:hidden;
  background:linear-gradient(140deg,#0a2233,#04101c);
  border:1px solid var(--edge);display:grid;place-items:center;position:relative;
}
.art img{width:100%;height:100%;object-fit:cover;display:block}
.art .ph{font-family:var(--display);font-size:28px;color:var(--dim);letter-spacing:0.1em}
.np-meta{min-width:0;flex:1}
.np-title{font-family:var(--display);font-size:22px;font-weight:600;line-height:1.15;letter-spacing:0.01em;word-break:break-word}
.np-sub{color:var(--muted);font-size:14px;margin-top:6px;word-break:break-word}
.np-src{margin-top:9px;display:inline-block;font-size:10px;letter-spacing:0.2em;text-transform:uppercase;color:var(--accent2);border:1px solid var(--edge);border-radius:999px;padding:4px 10px}
/* Progress */
.prog{margin-top:18px}
.bar{height:6px;border-radius:999px;background:rgba(255,255,255,0.08);overflow:hidden}
.bar>span{display:block;height:100%;width:0;border-radius:999px;background:linear-gradient(90deg,var(--accent),var(--accent2));box-shadow:0 0 12px var(--glow);transition:width .4s ease}
.activity{display:none;align-items:center;gap:10px;margin:12px 0 0;padding:10px 14px;border-radius:12px;background:rgba(255,255,255,0.04);border:1px solid var(--edge)}
.activity.on{display:flex}
.activity .spin{width:16px;height:16px;border-radius:50%;border:2px solid rgba(255,255,255,0.18);border-top-color:var(--accent);animation:orbspin .8s linear infinite;flex:0 0 auto}
.activity .alabel{font-size:13px;color:var(--ink);flex:1 1 auto;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.activity .abar{height:4px;flex:0 0 90px;border-radius:999px;background:rgba(255,255,255,0.08);overflow:hidden}
.activity .abar>span{display:block;height:100%;border-radius:999px;background:linear-gradient(90deg,var(--accent),var(--accent2));width:0;transition:width .3s ease}
.activity.indet .abar>span{width:40%;animation:orbslide 1.1s ease-in-out infinite}
@keyframes orbspin{to{transform:rotate(360deg)}}
@keyframes orbslide{0%{margin-left:-40%}100%{margin-left:100%}}
.times{display:flex;justify-content:space-between;color:var(--muted);font-size:12px;margin-top:7px;font-variant-numeric:tabular-nums}
/* Transport */
.transport{display:flex;align-items:center;justify-content:center;gap:14px;margin-top:20px}
.tbtn{
  width:54px;height:54px;border-radius:50%;border:1px solid var(--edge);
  background:rgba(10,20,34,0.7);color:var(--text);cursor:pointer;
  display:grid;place-items:center;transition:transform .12s,border-color .2s,box-shadow .2s,opacity .2s;
}
.tbtn svg{width:22px;height:22px;fill:currentColor}
.tbtn:hover:not([disabled]){border-color:var(--edge-strong);transform:translateY(-2px)}
.tbtn:active:not([disabled]){transform:scale(0.94)}
.tbtn.primary{
  width:72px;height:72px;border:none;color:#04121a;
  background:radial-gradient(circle at 38% 30%,var(--accent),#10b9e6 70%);
  box-shadow:0 0 26px var(--glow);
}
.tbtn[disabled]{opacity:0.32;cursor:not-allowed}
/* Volume */
.vol{margin-top:20px;display:flex;align-items:center;gap:14px}
.vol .ic{color:var(--muted);flex:0 0 auto}
.vol input[type=range]{
  -webkit-appearance:none;appearance:none;flex:1;height:6px;border-radius:999px;
  background:linear-gradient(90deg,var(--accent),var(--accent2)) no-repeat;
  background-size:var(--vol,60%) 100%;
  background-color:rgba(255,255,255,0.08);outline:none;cursor:pointer;
}
.vol input[type=range]::-webkit-slider-thumb{
  -webkit-appearance:none;width:20px;height:20px;border-radius:50%;
  background:#eafcff;box-shadow:0 0 0 4px rgba(56,225,255,0.25),0 2px 6px rgba(0,0,0,0.5);cursor:pointer;
}
.vol input[type=range]::-moz-range-thumb{width:20px;height:20px;border:none;border-radius:50%;background:#eafcff;box-shadow:0 0 0 4px rgba(56,225,255,0.25)}
.vol .pct{width:46px;text-align:right;color:var(--muted);font-size:13px;font-variant-numeric:tabular-nums}
/* Source buttons */
.sources{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));gap:10px}
.src{
  text-align:left;padding:13px 14px;border-radius:14px;cursor:pointer;
  border:1px solid var(--edge);background:rgba(10,18,30,0.5);color:var(--text);
  transition:border-color .2s,background .2s,transform .12s;position:relative;overflow:hidden;
}
.src:hover{transform:translateY(-2px)}
.src .st{font-family:var(--display);font-size:14px;font-weight:600;letter-spacing:0.04em}
.src .ss{font-size:11px;color:var(--muted);margin-top:3px}
.src::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--dim)}
.src[data-sev=active]::before{background:var(--accent2);box-shadow:0 0 10px var(--accent2)}
.src[data-sev=ready]::before{background:var(--accent)}
.src[data-sev=waiting]::before{background:var(--amber)}
.src[data-sev=failed]::before{background:var(--red)}
.src.sel{border-color:var(--edge-strong);background:rgba(20,40,60,0.7);box-shadow:0 0 0 1px var(--edge-strong),0 0 22px rgba(56,225,255,0.15)}
/* Panel note */
.note{margin-top:14px;padding:12px 14px;border-radius:12px;border:1px solid var(--edge);background:rgba(8,14,24,0.5);font-size:13px;color:var(--muted);line-height:1.5}
.note b{color:var(--text);font-weight:600}
.note.active{border-color:rgba(39,255,194,0.4)}
.note.waiting{border-color:rgba(255,180,84,0.4)}
.note.failed{border-color:rgba(255,93,114,0.45)}
/* Selects */
.field{margin-bottom:14px}
.field:last-child{margin-bottom:0}
.field label{display:block;font-size:11px;letter-spacing:0.16em;text-transform:uppercase;color:var(--muted);margin-bottom:7px}
select,input[type=search]{
  width:100%;font-family:var(--body);font-size:14px;color:var(--text);
  padding:12px 14px;border-radius:12px;border:1px solid var(--edge);
  background:rgba(8,14,24,0.7);outline:none;transition:border-color .2s;
}
select:focus,input[type=search]:focus{border-color:var(--accent)}
select{appearance:none;-webkit-appearance:none;background-image:linear-gradient(45deg,transparent 50%,var(--muted) 50%),linear-gradient(135deg,var(--muted) 50%,transparent 50%);background-position:calc(100% - 18px) center,calc(100% - 13px) center;background-size:5px 5px,5px 5px;background-repeat:no-repeat}
.statusline{font-size:12px;color:var(--muted);margin-top:10px}
.statusline b{color:var(--accent2);font-weight:600}
/* Music controls row */
.mrow{display:grid;grid-template-columns:1fr;gap:12px}
@media(min-width:520px){.mrow{grid-template-columns:1fr 1fr}}
.toolbar{display:flex;gap:10px;align-items:center;margin-top:6px}
.btn{
  font-family:var(--display);font-size:12px;letter-spacing:0.12em;text-transform:uppercase;
  padding:11px 16px;border-radius:11px;cursor:pointer;color:var(--text);
  border:1px solid var(--edge);background:rgba(10,20,34,0.6);transition:border-color .2s,transform .12s,background .2s;white-space:nowrap;
}
.btn:hover{border-color:var(--edge-strong);transform:translateY(-1px)}
.btn:active{transform:scale(0.96)}
.btn.ghost{background:transparent}
.btn.accent{border-color:var(--accent);color:var(--accent)}
.btn.danger{border-color:rgba(255,93,114,0.4);color:var(--red)}
.btn.sm{padding:8px 12px;font-size:11px}
/* Lists */
.list{margin-top:14px;display:flex;flex-direction:column;gap:8px;max-height:360px;overflow:auto;-webkit-overflow-scrolling:touch}
.list::-webkit-scrollbar{width:8px}
.list::-webkit-scrollbar-thumb{background:var(--edge);border-radius:8px}
.item{
  display:flex;align-items:center;gap:12px;padding:11px 13px;border-radius:12px;
  border:1px solid transparent;background:rgba(8,14,24,0.5);transition:border-color .2s,background .2s;
}
.item:hover{border-color:var(--edge)}
.item.cur{border-color:var(--accent2);background:rgba(20,46,40,0.45);box-shadow:0 0 18px rgba(39,255,194,0.12)}
.item.sel{border-color:var(--edge-strong)}
.item.pending{opacity:0.7}
.item .ix{width:24px;text-align:center;color:var(--dim);font-size:12px;font-variant-numeric:tabular-nums;flex:0 0 auto}
.item .body{min-width:0;flex:1}
.item .t{font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item .s{font-size:12px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.item .ch{flex:0 0 auto;font-size:10px;letter-spacing:0.08em;color:var(--accent);border:1px solid var(--edge);border-radius:999px;padding:3px 8px}
.item .acts{flex:0 0 auto;display:flex;gap:6px}
.iconbtn{
  width:34px;height:34px;border-radius:9px;border:1px solid var(--edge);background:rgba(12,22,36,0.7);
  color:var(--text);cursor:pointer;display:grid;place-items:center;transition:border-color .2s,transform .12s;
}
.iconbtn:hover{border-color:var(--edge-strong)}
.iconbtn:active{transform:scale(0.9)}
.iconbtn svg{width:16px;height:16px;fill:currentColor}
.iconbtn.play{color:var(--accent2)}
.empty{color:var(--dim);font-size:13px;text-align:center;padding:22px 0}
.tabs{display:flex;gap:8px;margin-top:8px}
.tab{flex:1;text-align:center;padding:9px;border-radius:10px;cursor:pointer;font-size:12px;letter-spacing:0.08em;text-transform:uppercase;color:var(--muted);border:1px solid var(--edge);background:transparent;transition:color .2s,border-color .2s}
.tab.on{color:var(--accent);border-color:var(--edge-strong);background:rgba(20,40,60,0.4)}
.count{margin-left:auto;font-size:11px;color:var(--dim);letter-spacing:0.1em}
/* Diagnostics */
.diag-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:6px}
.stepper{display:flex;align-items:center;gap:12px;margin:14px 0;justify-content:center}
.stepper .ch-num{font-family:var(--display);font-size:30px;font-weight:600;min-width:64px;text-align:center;font-variant-numeric:tabular-nums}
details.panel summary{list-style:none;cursor:pointer;display:flex;align-items:center}
details.panel summary::-webkit-details-marker{display:none}
details.panel summary h2{margin-bottom:0;width:100%}
details.panel[open] summary h2{margin-bottom:16px}
/* Footer */
footer{margin-top:26px;text-align:center;color:var(--dim);font-size:11px;letter-spacing:0.12em;line-height:1.8}
footer b{color:var(--muted);font-weight:600}
/* Toast */
#toast{
  position:fixed;left:50%;bottom:24px;transform:translateX(-50%) translateY(20px);
  background:rgba(12,22,36,0.95);border:1px solid var(--edge-strong);color:var(--text);
  padding:13px 20px;border-radius:12px;font-size:13px;max-width:90vw;text-align:center;
  opacity:0;pointer-events:none;transition:opacity .25s,transform .25s;z-index:50;
  box-shadow:0 14px 40px rgba(0,0,0,0.5);
}
#toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
#toast.err{border-color:rgba(255,93,114,0.6)}
</style>
</head>
<body>
<div class="shell">
  <header>
    <div class="orb"></div>
    <div class="brand">
      <h1>Orbisonic</h1>
      <div class="sub">Mission Control</div>
    </div>
    <div class="status-pill" id="statusPill"><span class="dot"></span><span id="statusLabel">Linking</span></div>
  </header>

  <div class="activity" id="activity" aria-live="polite">
    <span class="spin"></span>
    <span class="alabel" id="activityLabel"></span>
    <span class="abar"><span id="activityFill"></span></span>
  </div>

  <div class="grid">
    <div class="col">
      <!-- Now Playing -->
      <section class="panel">
        <h2>Now Playing</h2>
        <div class="np">
          <div class="art"><img id="art" hidden alt=""><span class="ph" id="artPh">&deg;</span></div>
          <div class="np-meta">
            <div class="np-title" id="npTitle">Nothing playing</div>
            <div class="np-sub" id="npSub"></div>
            <span class="np-src" id="npSrc" hidden></span>
            <div class="np-preload" id="preloadChip" hidden></div>
          </div>
        </div>
        <div class="prog">
          <div class="bar"><span id="progFill"></span></div>
          <div class="times"><span id="curTime">0:00</span><span id="durTime">0:00</span></div>
        </div>
        <div class="transport" id="transport">
          <button class="tbtn" data-cmd="playerControl" data-action="previous" title="Previous"><svg viewBox="0 0 24 24"><path d="M6 6h2v12H6zm3.5 6 8.5 6V6z"/></svg></button>
          <button class="tbtn primary" id="playPause" data-cmd="playerControl" data-action="play" title="Play"><svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></button>
          <button class="tbtn" data-cmd="playerControl" data-action="stop" title="Stop"><svg viewBox="0 0 24 24"><path d="M6 6h12v12H6z"/></svg></button>
          <button class="tbtn" data-cmd="playerControl" data-action="next" title="Next"><svg viewBox="0 0 24 24"><path d="M16 6h2v12h-2zM6 6l8.5 6L6 18z"/></svg></button>
        </div>
        <div class="vol">
          <span class="ic"><svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9zm13.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z"/></svg></span>
          <input type="range" id="vol" min="0" max="100" value="60">
          <span class="pct" id="volPct">60%</span>
        </div>
      </section>

      <!-- Source -->
      <section class="panel">
        <h2>Source</h2>
        <div class="sources" id="sources"></div>
        <div class="note" id="srcNote" hidden></div>
      </section>

      <!-- Routing -->
      <section class="panel">
        <h2>Routing</h2>
        <div class="field">
          <label>Monitor Output</label>
          <select id="monitorOut"></select>
        </div>
        <div class="field">
          <label>Renderer Output (Sphere)</label>
          <select id="rendererOut"></select>
        </div>
        <div class="statusline" id="routeStatus"></div>
      </section>
    </div>

    <div class="col">
      <!-- Local Music -->
      <section class="panel" id="musicPanel">
        <h2>Local Music <span class="count" id="trackCount"></span></h2>
        <div class="field">
          <input type="search" id="search" placeholder="Search tracks, artists, albums">
        </div>
        <div class="mrow">
          <div class="field" style="margin-bottom:0">
            <label>Sort</label>
            <select id="sort"><option value="Name">Name</option><option value="Artist">Artist</option><option value="Album">Album</option></select>
          </div>
          <div class="field" style="margin-bottom:0">
            <label>Channels</label>
            <select id="channels"></select>
          </div>
        </div>
        <div class="toolbar" style="margin-top:14px">
          <button class="btn ghost sm" data-cmd="rescan" title="Rescan library">Rescan Library</button>
        </div>
        <div class="tabs">
          <button class="tab on" data-tab="tracks">Tracks</button>
          <button class="tab" data-tab="playlists">Playlists</button>
          <button class="tab" data-tab="queue">Queue</button>
        </div>
        <div class="list" id="trackList" data-view="tracks"></div>
        <div class="list" id="playlistList" data-view="playlists" hidden></div>
        <div class="list" id="queueList" data-view="queue" hidden></div>
        <div class="toolbar" id="queueTools" hidden style="margin-top:12px">
          <button class="btn danger sm" data-cmd="queue" data-action="clear">Clear Queue</button>
        </div>
      </section>

      <!-- Diagnostics -->
      <details class="panel" id="diagPanel">
        <summary><h2>Diagnostics</h2></summary>
        <div class="statusline" id="diagStatus"></div>
        <div class="stepper">
          <button class="iconbtn" id="chDown"><svg viewBox="0 0 24 24"><path d="M19 13H5v-2h14z"/></svg></button>
          <div class="ch-num" id="chNum">1</div>
          <button class="iconbtn" id="chUp"><svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z"/></svg></button>
        </div>
        <div class="diag-grid">
          <button class="btn accent sm" id="playTone">Play Tone</button>
          <button class="btn sm" data-cmd="diagnostics" data-action="monitorWalk">Monitor Walk</button>
          <button class="btn sm" data-cmd="diagnostics" data-action="rendererWalk">Renderer Walk</button>
          <button class="btn danger sm" data-cmd="diagnostics" data-action="stop">Stop</button>
        </div>
      </details>
    </div>
  </div>

  <footer>
    <div><b id="fAppStatus">Orbisonic</b> &middot; <span id="fServer"></span></div>
    <div id="fVersion"></div>
    <div id="fError" style="color:var(--red)"></div>
  </footer>
</div>
<div id="toast"></div>

<script>
const TOKEN = "\(token)";
const API={
  state:'/Orbisonic/api/state',
  playerControl:'/Orbisonic/api/player/control',
  playerVolume:'/Orbisonic/api/player/volume',
  inputSource:'/Orbisonic/api/input/source',
  inputMonitor:'/Orbisonic/api/input/monitor',
  monitorOutput:'/Orbisonic/api/routing/monitor-output',
  rendererOutput:'/Orbisonic/api/routing/renderer-output',
  search:'/Orbisonic/api/local-music/search',
  track:'/Orbisonic/api/local-music/track',
  playlist:'/Orbisonic/api/local-music/playlist',
  queue:'/Orbisonic/api/local-music/queue',
  rescan:'/Orbisonic/api/local-music/rescan',
  diagnostics:'/Orbisonic/api/diagnostics'
};
const $=id=>document.getElementById(id);
function esc(v){return String(v==null?'':v).split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;').split('"').join('&quot;');}
function clean(v){const t=String(v==null?'':v).trim();return t==='-'?'':t;}
let lastState=null;
let userBusy=false;        // true while dragging volume / typing search
let diagChannel=1;
let diagTouched=false;
let activeView='tracks';

/* ---- networking ---- */
function authHeaders(){return {'x-orbisonic-token':TOKEN,'content-type':'application/json'};}
async function getState(){
  const r=await fetch(API.state,{cache:'no-store',headers:{'x-orbisonic-token':TOKEN}});
  if(!r.ok)throw new Error('state '+r.status);
  return r.json();
}
async function send(path,body){
  try{
    const r=await fetch(path,{method:'POST',headers:authHeaders(),body:JSON.stringify(body||{})});
    const j=await r.json();
    if(j&&j.state)render(j.state);
    if(j&&j.message&&clean(j.message))flash(clean(j.message),j.ok===false);
    return j;
  }catch(e){flash('Command failed',true);}
}
function flash(msg,isErr){
  const t=$('toast');t.textContent=msg;t.className='show'+(isErr?' err':'');
  clearTimeout(flash._t);flash._t=setTimeout(()=>{t.className='';},2600);
}

/* ---- formatting ---- */
function setConn(ok){
  const p=$('statusPill');
  p.className='status-pill '+(ok?'live':'stale');
  $('statusLabel').textContent=ok?'Live':'Reconnecting';
}

/* ---- render ---- */
function render(s){
  if(!s)return;lastState=s;
  renderActivity(s.activity);
  renderPreload(s.preload);
  renderPlayer(s.player);
  renderSources(s.input);
  renderRouting(s.routing);
  renderMusic(s.localMusic);
  renderDiagnostics(s.diagnostics);
  renderBuild(s.build);
}

function renderActivity(a){
  const el=$('activity');if(!el)return;
  if(!a||!a.isBusy){el.classList.remove('on');return;}
  el.classList.add('on');
  $('activityLabel').textContent=clean(a.label)||'Working...';
  const indet=Boolean(a.isIndeterminate);
  el.classList.toggle('indet',indet);
  const fill=$('activityFill');
  if(indet){fill.style.width='';}
  else{const p=Math.max(0,Math.min(1,Number(a.progress)||0));fill.style.width=(p*100)+'%';}
}

function renderPreload(p){
  const el=$('preloadChip');if(!el)return;
  if(!p||!p.enabled){el.hidden=true;return;}
  el.hidden=false;
  const next=clean(p.nextLabel)||'—';
  el.textContent='Next: '+next+' — '+(clean(p.statusLabel)||'Idle');
}

function renderPlayer(p){
  if(!p)return;
  const media=Boolean(p.hasMedia);
  $('npTitle').textContent=media?(clean(p.title)||'Untitled'):'Nothing playing';
  const sub=[clean(p.artist),clean(p.album)].filter(Boolean).join('  —  ')||clean(p.subtitle);
  $('npSub').textContent=media?sub:'Awaiting a source';
  const src=$('npSrc');const sn=clean(p.sourceName)||clean(p.source);
  src.hidden=!sn;src.textContent=sn;
  // artwork
  const art=$('art'),ph=$('artPh');
  if(p.artworkURL){if(art.getAttribute('src')!==p.artworkURL)art.src=p.artworkURL;art.hidden=false;ph.hidden=true;art.onerror=()=>{art.hidden=true;ph.hidden=false;};}
  else{art.removeAttribute('src');art.hidden=true;ph.hidden=false;}
  // progress
  const prog=Math.max(0,Math.min(1,Number(p.progress)||0));
  $('progFill').style.width=(prog*100)+'%';
  $('curTime').textContent=clean(p.currentTime)||'0:00';
  $('durTime').textContent=clean(p.duration)||'0:00';
  // transport
  const en=p.enabledControls||[];
  const isPlaying=Boolean(p.isPlaying);
  const pp=$('playPause');
  pp.dataset.action=isPlaying?'pause':'play';
  pp.title=isPlaying?'Pause':'Play';
  pp.innerHTML=isPlaying?'<svg viewBox="0 0 24 24"><path d="M6 5h4v14H6zm8 0h4v14h-4z"/></svg>':'<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>';
  pp.disabled=!(en.includes(isPlaying?'pause':'play'));
  $('transport').querySelectorAll('[data-action=previous]').forEach(b=>b.disabled=!en.includes('previous'));
  $('transport').querySelectorAll('[data-action=next]').forEach(b=>b.disabled=!en.includes('next'));
  $('transport').querySelectorAll('[data-action=stop]').forEach(b=>b.disabled=!media);
  // volume
  if(!userBusy){
    const v=Math.max(0,Math.min(100,Number(p.volume)||0));
    const slider=$('vol');slider.value=v;slider.style.setProperty('--vol',v+'%');
    $('volPct').textContent=v+'%';
  }
}

function renderSources(input){
  if(!input){$('sources').innerHTML='';return;}
  const btns=input.sourceButtons||[];
  $('sources').innerHTML=btns.map(b=>{
    return '<button class="src'+(b.isSelected?' sel':'')+'" data-sev="'+esc(b.severity)+'" data-cmd="inputSource" data-value="'+esc(b.value)+'">'
      +'<div class="st">'+esc(b.title)+'</div>'
      +(clean(b.subtitle)?'<div class="ss">'+esc(b.subtitle)+'</div>':'')
      +'</button>';
  }).join('')||'<div class="empty">No sources available</div>';
  const panel=input.sourcePanel;const note=$('srcNote');
  if(panel&&(clean(panel.headline)||clean(panel.body))){
    note.hidden=false;note.className='note '+esc(panel.severity||'');
    note.innerHTML=(clean(panel.headline)?'<b>'+esc(panel.headline)+'</b><br>':'')+esc(clean(panel.body));
  }else{note.hidden=true;}
}

function routeOptions(opts,selectedId){
  return (opts||[]).map(o=>{
    const sel=o.isSelected?' selected':'';
    const dis=o.isSelectable===false?' disabled':'';
    const detail=clean(o.detail)?'  ('+o.detail+')':'';
    return '<option value="'+esc(o.id)+'"'+sel+dis+'>'+esc(o.name)+esc(detail)+'</option>';
  }).join('');
}
function renderRouting(r){
  if(!r)return;
  const mo=$('monitorOut'),ro=$('rendererOut');
  if(document.activeElement!==mo)mo.innerHTML=routeOptions(r.monitorOptions);
  if(document.activeElement!==ro)ro.innerHTML=routeOptions(r.rendererOptions);
  const bits=[];
  if(clean(r.monitorStatus))bits.push('Monitor: <b>'+esc(clean(r.monitorStatus))+'</b>');
  if(clean(r.rendererStatus))bits.push('Renderer: <b>'+esc(clean(r.rendererStatus))+'</b>');
  if(clean(r.rendererScene))bits.push(esc(clean(r.rendererScene)));
  $('routeStatus').innerHTML=bits.join('  &middot;  ');
}

function renderMusic(m){
  const panel=$('musicPanel');
  if(!m){panel.hidden=true;return;}
  panel.hidden=false;
  $('trackCount').textContent=(m.count!=null?m.count:(m.tracks||[]).length)+' tracks';
  if(document.activeElement!==$('search'))$('search').value=clean(m.search);
  if(document.activeElement!==$('sort'))$('sort').value=m.sort||'Name';
  // channel filter
  const chSel=$('channels');
  if(document.activeElement!==chSel){
    const counts=m.availableChannelCounts||[];
    const cur=Number(m.channelFilter)||0;
    chSel.innerHTML='<option value="0">All</option>'+counts.map(c=>'<option value="'+c+'"'+(c===cur?' selected':'')+'>'+c+' ch</option>').join('');
    chSel.value=String(cur);
  }
  // tracks
  $('trackList').innerHTML=(m.tracks||[]).map(t=>{
    const cls='item'+(t.isCurrent?' cur':'')+(t.isSelected?' sel':'')+(t.isPending?' pending':'');
    return '<div class="'+cls+'" data-cmd="track" data-action="select" data-id="'+esc(t.id)+'">'
      +'<div class="body"><div class="t">'+esc(t.title)+'</div>'+(clean(t.subtitle)?'<div class="s">'+esc(t.subtitle)+'</div>':'')+'</div>'
      +(clean(t.channels)?'<span class="ch">'+esc(t.channels)+'</span>':'')
      +'<div class="acts">'
      +'<button class="iconbtn play" data-cmd="track" data-action="play" data-id="'+esc(t.id)+'" title="Play now"><svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></button>'
      +'<button class="iconbtn" data-cmd="track" data-action="add" data-id="'+esc(t.id)+'" title="Add to queue"><svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z"/></svg></button>'
      +'</div></div>';
  }).join('')||'<div class="empty">No tracks match</div>';
  // playlists
  $('playlistList').innerHTML=(m.playlists||[]).map(p=>{
    const cls='item'+(p.isSelected?' sel':'');
    return '<div class="'+cls+'" data-cmd="playlist" data-action="select" data-id="'+esc(p.id)+'">'
      +'<div class="body"><div class="t">'+esc(p.name)+'</div><div class="s">'+esc(p.trackCount)+' tracks</div></div>'
      +'<div class="acts">'
      +'<button class="iconbtn play" data-cmd="playlist" data-action="play" data-id="'+esc(p.id)+'" title="Play playlist"><svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></button>'
      +'<button class="iconbtn" data-cmd="playlist" data-action="add" data-id="'+esc(p.id)+'" title="Queue playlist"><svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z"/></svg></button>'
      +'</div></div>';
  }).join('')||'<div class="empty">No playlists</div>';
  // queue
  const q=m.sessionQueue||[];
  $('queueList').innerHTML=q.map(it=>{
    const cls='item'+(it.isCurrent?' cur':'')+(it.isSelected?' sel':'')+(it.isPending?' pending':'');
    return '<div class="'+cls+'" data-cmd="queue" data-action="select" data-index="'+it.index+'">'
      +'<div class="ix">'+(it.index+1)+'</div>'
      +'<div class="body"><div class="t">'+esc(it.title)+'</div>'+(clean(it.subtitle)?'<div class="s">'+esc(it.subtitle)+'</div>':'')+'</div>'
      +'<div class="acts">'
      +'<button class="iconbtn play" data-cmd="queue" data-action="play" data-index="'+it.index+'" title="Play"><svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></button>'
      +'<button class="iconbtn" data-cmd="queue" data-action="up" data-index="'+it.index+'" title="Move up"><svg viewBox="0 0 24 24"><path d="M12 8l6 6H6z"/></svg></button>'
      +'<button class="iconbtn" data-cmd="queue" data-action="down" data-index="'+it.index+'" title="Move down"><svg viewBox="0 0 24 24"><path d="M12 16l-6-6h12z"/></svg></button>'
      +'<button class="iconbtn" data-cmd="queue" data-action="remove" data-index="'+it.index+'" title="Remove"><svg viewBox="0 0 24 24"><path d="M19 13H5v-2h14z"/></svg></button>'
      +'</div></div>';
  }).join('')||'<div class="empty">Queue is empty</div>';
  $('queueTools').hidden=q.length===0;
}

function renderDiagnostics(d){
  if(!d)return;
  const bits=[];
  if(clean(d.toneStatus))bits.push('<b>'+esc(clean(d.toneStatus))+'</b>');
  if(d.monitorChannelCount)bits.push('Monitor '+d.monitorChannelCount+'ch');
  if(d.rendererChannelCount)bits.push('Renderer '+d.rendererChannelCount+'ch');
  $('diagStatus').innerHTML=bits.join('  &middot;  ')||'Idle';
  if(!diagTouched){diagChannel=(Number(d.selectedChannel)||0)+1;$('chNum').textContent=diagChannel;}
}

function renderBuild(b){
  if(!b)return;
  $('fAppStatus').textContent=clean(b.appStatus)||'Orbisonic';
  $('fServer').textContent=clean(b.webServer);
  const ver=[clean(b.appVersion)&&('v'+clean(b.appVersion)),clean(b.buildNumber)&&('build '+clean(b.buildNumber)),clean(b.machineIP)].filter(Boolean).join('  ·  ');
  $('fVersion').textContent=ver;
  $('fError').textContent=clean(b.lastError);
}

/* ---- events ---- */
document.addEventListener('click',e=>{
  const el=e.target.closest('[data-cmd]');
  if(!el||el.disabled)return;
  const path=API[el.dataset.cmd];
  if(!path)return;
  const body={};
  const d=el.dataset;
  if(d.action!=null)body.action=d.action;
  if(d.id!=null)body.id=d.id;
  if(d.value!=null)body.value=d.value;
  if(d.index!=null)body.index=Number(d.index);
  if(d.shuffle!=null)body.shuffle=d.shuffle==='true';
  send(path,body);
});

// volume drag
const vol=$('vol');
function volInput(){userBusy=true;const v=Number(vol.value);vol.style.setProperty('--vol',v+'%');$('volPct').textContent=v+'%';}
function volCommit(){send(API.playerVolume,{value:String(vol.value)});setTimeout(()=>{userBusy=false;},400);}
vol.addEventListener('input',volInput);
vol.addEventListener('change',volCommit);

// routing selects
$('monitorOut').addEventListener('change',e=>send(API.monitorOutput,{value:e.target.value}));
$('rendererOut').addEventListener('change',e=>send(API.rendererOutput,{value:e.target.value}));

// search + sort + channels
let searchTimer=null;
function pushSearch(){
  send(API.search,{query:$('search').value,sort:$('sort').value,channels:Number($('channels').value)||0});
}
$('search').addEventListener('input',()=>{userBusy=true;clearTimeout(searchTimer);searchTimer=setTimeout(pushSearch,280);});
$('search').addEventListener('blur',()=>{userBusy=false;});
$('sort').addEventListener('change',pushSearch);
$('channels').addEventListener('change',pushSearch);

// tabs
document.querySelectorAll('.tab').forEach(t=>t.addEventListener('click',()=>{
  activeView=t.dataset.tab;
  document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('on',x===t));
  ['tracks','playlists','queue'].forEach(v=>{
    const list=document.querySelector('.list[data-view='+v+']');if(list)list.hidden=(v!==activeView);
  });
}));

// diagnostics stepper
function clampCh(n){return Math.max(1,Math.min(30,n));}
$('chDown').addEventListener('click',()=>{diagTouched=true;diagChannel=clampCh(diagChannel-1);$('chNum').textContent=diagChannel;});
$('chUp').addEventListener('click',()=>{diagTouched=true;diagChannel=clampCh(diagChannel+1);$('chNum').textContent=diagChannel;});
$('playTone').addEventListener('click',()=>send(API.diagnostics,{action:'testTone',index:diagChannel-1}));

/* ---- poll loop ---- */
async function tick(){
  try{const s=await getState();setConn(true);render(s);}
  catch(e){setConn(false);}
}
tick();
setInterval(tick,1500);
</script>
</body>
</html>
"""
    }
}
