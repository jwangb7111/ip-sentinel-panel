/* IP-Sentinel 控制台 · 前端
   原生 JS，无构建步骤 */

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const view = $('#view');
const state = { nodes: [], timer: null };

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

const fmtTime = (s) => {
  if (!s) return '—';
  return String(s).replace(/^\d{4}-/, '').replace(' ', ' ');
};

function toast(msg, kind = '') {
  const t = $('#toast');
  t.textContent = msg;
  t.className = 'toast show ' + kind;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { t.className = 'toast ' + kind; }, 2600);
}

async function api(path, opts = {}) {
  const res = await fetch(path, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    ...opts,
  });
  if (res.status === 401) { showLogin(); throw new Error('unauthorized'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

/* ---------------- 登录 ---------------- */
function showLogin() {
  $('#app').classList.add('hidden');
  $('#login').classList.remove('hidden');
  setTimeout(() => $('#password')?.focus(), 60);
}
function showApp() {
  $('#login').classList.add('hidden');
  $('#app').classList.remove('hidden');
  route();
}

$('#login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = e.target.querySelector('button');
  const err = $('#login-error');
  err.textContent = '';
  btn.disabled = true;
  try {
    await api('/api/login', { method: 'POST', body: JSON.stringify({ password: $('#password').value }) });
    $('#password').value = '';
    showApp();
  } catch (ex) {
    err.textContent = ex.message === 'unauthorized' ? '口令错误' : ex.message;
  } finally {
    btn.disabled = false;
  }
});

$('#logout-btn').addEventListener('click', async () => {
  await api('/api/logout', { method: 'POST' }).catch(() => {});
  showLogin();
});

/* ---------------- 导航 ---------------- */
$('#menu-btn').addEventListener('click', () => document.body.classList.toggle('nav-open'));
$('#settings-btn').addEventListener('click', () => { location.hash = '#/settings'; });
$('#scrim').addEventListener('click', () => document.body.classList.remove('nav-open'));
$('#refresh-btn').addEventListener('click', () => route(true));

window.addEventListener('hashchange', () => {
  document.body.classList.remove('nav-open');
  route();
});

function setNav(name) {
  $$('.nav a').forEach((a) => a.classList.toggle('active', a.dataset.nav === name));
}

/* ---------------- 路由 ---------------- */
async function route(force) {
  clearInterval(state.timer);
  const hash = location.hash.replace(/^#\/?/, '') || 'dashboard';
  const [page, arg] = hash.split('/');

  try {
    if (page === 'node' && arg) {
      setNav('fleet');
      $('#crumbs').textContent = '节点详情';
      await renderNode(decodeURIComponent(arg));
      state.timer = setInterval(() => { if (document.visibilityState === 'visible') route(true); }, 30000);
      return;
    }
    if (page === 'fleet') {
      setNav('fleet');
      $('#crumbs').textContent = '舰队';
      await renderFleet();
    } else if (page === 'audit') {
      setNav('audit');
      $('#crumbs').textContent = '命令审计';
      await renderAudit();
    } else if (page === 'settings') {
      setNav('settings');
      $('#crumbs').textContent = '设置';
      await renderSettings();
    } else {
      setNav('dashboard');
      $('#crumbs').textContent = '总览';
      await renderDashboard();
    }
    state.timer = setInterval(() => {
      if (document.visibilityState === 'visible' && location.hash.indexOf('node/') === -1) route(true);
    }, 20000);
  } catch (ex) {
    if (ex.message !== 'unauthorized') {
      view.innerHTML = `<div class="card panel"><div class="empty">加载失败：${esc(ex.message)}</div></div>`;
    }
  }
}

/* ---------------- 总览 ---------------- */
async function renderDashboard() {
  const [{ nodes }, stats] = await Promise.all([api('/api/nodes'), api('/api/stats')]);
  state.nodes = nodes;
  const online = nodes.filter((n) => isOnline(n)).length;
  updateSide(online, nodes.length);

  view.innerHTML = `
    <div class="stats">
      ${statCard('节点总数', nodes.length, '已纳管边缘哨兵')}
      ${statCard('在线节点', online, online === nodes.length && nodes.length ? '全部心跳正常' : '部分节点待探测')}
      ${statCard('按时运行', `${stats.ontime ?? 0}/${stats.active ?? nodes.length}`, '40 分钟内有运行记录')}
      ${statCard('24h 运行', stats.runs_24h ?? 0, 'Agent 已完成轮次')}
    </div>

    <div class="section-head">
      <h2>舰队概览</h2>
      <div class="spacer"></div>
      <button class="btn sm" id="quick-add">＋ 添加节点</button>
    </div>
    ${nodes.length ? fleetBody(nodes) : emptyState()}
  `;
  bindCommon();
}

/* 主控独占第一排，子节点从第二排开始 */
function fleetBody(nodes) {
  const pending = nodes.filter((n) => (n.status || 'active') !== 'active');
  const active = nodes.filter((n) => (n.status || 'active') === 'active');
  const masters = active.filter((n) => n.is_local);
  const children = active.filter((n) => !n.is_local);
  let html = '';
  if (pending.length) {
    html += `<div class="section-head pending-head"><h2>待审批</h2><span class="tag warn">${pending.length}</span></div>
      <div class="pending-list">${pending.map(pendingCard).join('')}</div>`;
  }
  if (masters.length) {
    html += `<div class="section-head"><h2>主控</h2><span class="tag mute">${masters.length} 台</span></div>
      <div class="master-list">${masters.map(masterCard).join('')}</div>`;
  }
  html += `<div class="section-head nodes-head"><h2>子节点</h2><span class="tag mute">${children.length} 台</span></div>`;
  html += children.length ? groupedHtml(children) : emptyChildren();
  return html;
}

function pendingCard(n) {
  return `<div class="card pending-card">
    <div class="pending-main">
      <div class="node-name">${esc(n.alias || n.id)}</div>
      <div class="node-region">${esc(n.region || '未设置战区')} · ${esc(n.ip)}:${esc(n.port)}${n.agent_version ? ' · v' + esc(n.agent_version) : ''}</div>
    </div>
    <div class="pending-state">${n.reachable ? '<span class="tag ok">可达</span>' : '<span class="tag bad">不可达</span>'}</div>
    <div class="pending-actions">
      <button class="btn sm primary" data-approve="${esc(n.id)}">通过</button>
      <button class="btn sm danger" data-reject="${esc(n.id)}">拒绝</button>
    </div>
  </div>`;
}

function masterCard(n) {
  return `<div class="card master-card" data-node="${esc(n.id)}">
    <div class="master-main">
      <div class="node-icon big">
        <svg viewBox="0 0 24 24"><path d="M12 2l9 4v6c0 5.25-3.84 9.74-9 10-5.16-.26-9-4.75-9-10V6l9-4z"/></svg>
      </div>
      <div class="node-title">
        <div class="node-name" title="${esc(n.alias || n.id)}">${esc(n.alias || n.id)}</div>
        <div class="node-region">${esc(n.region || '未设置战区')} · 主控本机</div>
      </div>
      <div class="node-state">${statusTag(n)}</div>
    </div>
    <div class="master-stats">
      <div class="ms"><span>出口 IP</span><b>${esc(n.ip)}</b></div>
      <div class="ms"><span>端口</span><b>${esc(n.port)}</b></div>
      <div class="ms"><span>心跳</span><b>${n.last_seen ? fmtTime(n.last_seen) : '—'}</b></div>
      <div class="ms"><span>上次运行</span><b>${runAgo(n.last_run_at) || '—'}</b></div>
      <div class="ms"><span>模块</span><b>${n.enable_google ? 'G' : '–'} / ${n.enable_trust ? 'T' : '–'}</b></div>
    </div>
    <div class="master-actions">
      <button class="btn sm" data-act="run" data-id="${esc(n.id)}">立即养护</button>
      <button class="btn sm" data-act="log" data-id="${esc(n.id)}">日志</button>
      <a class="btn sm primary" href="#/node/${encodeURIComponent(n.id)}">详情</a>
    </div>
  </div>`;
}

function emptyChildren() {
  return `<div class="card panel empty-children">
    <div class="empty">还没有子节点<br>
      <button class="btn sm primary" id="quick-add-2" style="margin-top:12px">添加子节点</button>
    </div>
  </div>`;
}

function groupedHtml(nodes) {
  const groups = {};
  for (const n of nodes) {
    const key = n.region || '未设置战区';
    (groups[key] = groups[key] || []).push(n);
  }
  return Object.keys(groups).sort().map((region) => `
    <div class="section-head region-head">
      <h2>${esc(region)}</h2>
      <span class="tag mute">${groups[region].length} 个节点</span>
    </div>
    <div class="grid">${groups[region].map(nodeCard).join('')}</div>
  `).join('');
}

function statCard(label, value, hint) {
  return `<div class="card stat">
    <div class="label">${esc(label)}</div>
    <div class="value">${esc(value)}</div>
    <div class="hint">${esc(hint)}</div>
  </div>`;
}

function isOnline(n) {
  if (!n.last_seen) return false;
  const t = Date.parse(n.last_seen.replace(' ', 'T') + 'Z');
  return Date.now() - t < 5 * 60 * 1000;
}

function runAgo(ts) {
  if (!ts) return null;
  const t = Date.parse(ts.replace(' ', 'T') + 'Z');
  if (!Number.isFinite(t)) return null;
  const m = Math.max(0, Math.round((Date.now() - t) / 60000));
  if (m < 1) return '刚刚';
  if (m < 60) return m + ' 分钟前';
  const h = Math.floor(m / 60);
  if (h < 24) return h + ' 小时前';
  return Math.floor(h / 24) + ' 天前';
}

function isRunFresh(n) {
  if (!n.last_run_at) return false;
  const t = Date.parse(n.last_run_at.replace(' ', 'T') + 'Z');
  return Number.isFinite(t) && Date.now() - t < 40 * 60 * 1000;
}

/* 定时任务是否有运行记录；超过 40 分钟没动静就算超期（20 分钟一轮 + 容忍） */
function runTag(n) {
  const ago = runAgo(n.last_run_at);
  if (!ago) return '<span class="tag mute">运行记录待采集</span>';
  if (!isRunFresh(n)) return `<span class="tag warn">上次运行 ${ago} · 超期</span>`;
  if (n.last_run_status === 'running') return `<span class="tag ok">运行中 · ${ago}</span>`;
  if (n.last_run_status === 'fail') return `<span class="tag bad">上次失败 · ${ago}</span>`;
  const mod = n.last_run_action ? ' · ' + n.last_run_action : '';
  return `<span class="tag ok">上次运行 ${ago}${mod}</span>`;
}

function statusTag(n) {
  if (!n.last_seen) return '<span class="tag mute">待探测</span>';
  return isOnline(n)
    ? '<span class="tag ok"><span class="dot ok" style="width:6px;height:6px"></span>在线</span>'
    : '<span class="tag bad"><span class="dot bad" style="width:6px;height:6px"></span>离线</span>';
}

function nodeCard(n) {
  return `<div class="card node" data-node="${esc(n.id)}">
    <div class="node-top">
      <div class="node-icon">
        <svg viewBox="0 0 24 24"><path d="M4 5h16v4H4V5zm0 6h16v4H4v-4zm0 6h16v2H4v-2z"/></svg>
      </div>
      <div class="node-title">
        <div class="node-name" title="${esc(n.alias || n.id)}">${esc(n.alias || n.id)}</div>
        <div class="node-region" title="${esc(n.region || '')}">${esc(n.region || '未设置战区')}${n.is_local ? ' · 主控本机' : ''}</div>
      </div>
      <div class="node-state">${statusTag(n)}</div>
    </div>
    <div class="node-meta">
      <span class="tag">${esc(n.ip)}:${esc(n.port)}</span>
      <span class="tag ${n.enable_google ? 'ok' : 'mute'}">Google ${n.enable_google ? '开' : '关'}</span>
      <span class="tag ${n.enable_trust ? 'ok' : 'mute'}">净化 ${n.enable_trust ? '开' : '关'}</span>
      <span class="tag mute">${n.last_seen ? '心跳 ' + fmtTime(n.last_seen) : '暂无心跳'}</span>
      ${runTag(n)}
    </div>
    <div class="node-actions">
      <button class="btn sm" data-act="run" data-id="${esc(n.id)}">立即养护</button>
      <button class="btn sm" data-act="log" data-id="${esc(n.id)}">日志</button>
      <a class="btn sm primary" href="#/node/${encodeURIComponent(n.id)}">详情</a>
    </div>
  </div>`;
}

function emptyState() {
  return `<div class="card panel">
    <div class="empty">
      还没有纳管任何节点。<br>
      <button class="btn sm primary" id="quick-add" style="margin-top:12px">添加第一个节点</button>
    </div>
  </div>`;
}

/* ---------------- 舰队 ---------------- */
async function renderFleet() {
  const { nodes } = await api('/api/nodes');
  state.nodes = nodes;
  updateSide(nodes.filter(isOnline).length, nodes.length);
  view.innerHTML = `
    <div class="section-head">
      <h2>舰队 · ${nodes.length} 个节点</h2>
      <div class="spacer"></div>
      <button class="btn sm primary" id="quick-add">＋ 添加节点</button>
    </div>

    <div class="card panel batch-bar">
      <div class="batch-row">
        <span class="batch-label">全舰队下发</span>
        <button class="btn sm" data-batch="run">立即养护</button>
        <button class="btn sm" data-batch="google">Google 纠偏</button>
        <button class="btn sm" data-batch="trust">信用净化</button>
        <button class="btn sm" data-batch="quality">质量探针</button>
        <button class="btn sm danger" data-batch="ota">OTA 全量</button>
      </div>
      <div id="batch-progress" class="batch-progress hidden"></div>
    </div>

    ${nodes.length ? fleetBody(nodes) : emptyState()}
  `;
  bindCommon();
  $$('[data-batch]').forEach((b) => b.addEventListener('click', () => runBatch(b.dataset.batch, b)));
}

async function decideNode(id, approve) {
  if (!approve && !confirm('拒绝并删除该注册申请？')) return;
  try {
    await api('/api/nodes/' + encodeURIComponent(id) + (approve ? '/approve' : '/reject'), { method: 'POST' });
    toast(approve ? '节点已通过' : '已拒绝', 'ok');
    route(true);
  } catch (ex) { toast(ex.message, 'err'); }
}

async function runBatch(action, btn) {
  if (action === 'ota' && !confirm('确定让全部节点拉取最新代码并热重载？\n每条节点会短暂中断。')) return;
  const old = btn.textContent;
  btn.disabled = true; btn.textContent = '下发中…';
  try {
    const { batch_id, total } = await api('/api/batch', {
      method: 'POST', body: JSON.stringify({ action }),
    });
    toast(`已下发 ${total} 个节点`, 'ok');
    trackBatch(batch_id, total);
  } catch (ex) {
    toast(ex.message, 'err');
  } finally {
    btn.disabled = false; btn.textContent = old;
  }
}

function trackBatch(id, total) {
  const box = $('#batch-progress');
  if (!box) return;
  box.classList.remove('hidden');
  const tick = async () => {
    try {
      const r = await api('/api/batch/' + encodeURIComponent(id));
      const c = r.counts || {};
      const done = (c.done || 0) + (c.failed || 0);
      const pct = r.total ? Math.round(done * 100 / r.total) : 0;
      box.innerHTML = `
        <div class="bar"><div class="bar-fill" style="width:${pct}%"></div></div>
        <div class="batch-meta">完成 ${done}/${r.total} · 失败 ${c.failed || 0} · 进行中 ${c.running || 0} · 排队 ${c.queued || 0}</div>`;
      if (done >= r.total) {
        clearInterval(box._t);
        setTimeout(() => route(true), 900);
      }
    } catch (_) { /* 忽略 */ }
  };
  clearInterval(box._t);
  tick();
  box._t = setInterval(tick, 1200);
}

/* ---------------- 节点详情 ---------------- */
async function renderNode(id) {
  const { nodes } = await api('/api/nodes');
  const n = nodes.find((x) => x.id === id);
  if (!n) { view.innerHTML = '<div class="card panel"><div class="empty">节点不存在</div></div>'; return; }
  state.nodes = nodes;

  view.innerHTML = `
    <a class="back" href="#/fleet">← 返回舰队</a>
    <div class="detail-head" style="margin-top:12px">
      <h1>${esc(n.alias || n.id)}</h1>
      ${statusTag(n)}
      <button class="icon-btn" id="rename-btn" data-id="${esc(n.id)}" title="修改别名">
        <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.8 9.94l-3.75-3.75L3 17.25zM20.71 7.04a1 1 0 000-1.41l-2.34-2.34a1 1 0 00-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
      </button>
      <div class="meta">${esc(n.region || '未设置战区')} · ${esc(n.ip)}:${esc(n.port)}</div>
      <div class="meta">${runTag(n)}</div>
    </div>

    <div class="card panel">
      <h3>操作</h3>
      <div class="action-bar">
        <button class="btn primary" data-act="run" data-id="${esc(n.id)}">立即养护</button>
        <button class="btn" data-act="google" data-id="${esc(n.id)}">Google 纠偏</button>
        <button class="btn" data-act="trust" data-id="${esc(n.id)}">信用净化</button>
        <button class="btn" data-act="report" data-id="${esc(n.id)}">生成战报</button>
        <button class="btn" data-act="quality" data-id="${esc(n.id)}">质量探针</button>
        <button class="btn" data-act="log" data-id="${esc(n.id)}">拉取日志</button>
        <button class="btn danger" data-act="ota" data-id="${esc(n.id)}">OTA 升级</button>
        <button class="btn danger" id="del-btn" data-id="${esc(n.id)}">删除节点</button>
      </div>
    </div>

    <div class="card panel">
      <h3>模块开关</h3>
      <div class="switches">
        <label class="switch"><input type="checkbox" data-toggle="enable_google" ${n.enable_google ? 'checked' : ''}> Google 区域纠偏</label>
        <label class="switch"><input type="checkbox" data-toggle="enable_trust" ${n.enable_trust ? 'checked' : ''}> IP 信用净化</label>
      </div>
    </div>

    <div class="card panel">
      <h3>信用趋势</h3>
      <div class="chart-wrap" id="chart-wrap"><div class="empty">暂无趋势数据，跑一轮「质量探针」后自动生成</div></div>
    </div>

    <div class="card panel">
      <h3>运行日志</h3>
      <pre class="log" id="log-box">点击上方「拉取日志」加载</pre>
    </div>
  `;

  bindCommon();
  $$('[data-toggle]').forEach((el) => el.addEventListener('change', () => toggleModule(n.id, el.dataset.toggle, el.checked)));
  const rb = $('#rename-btn');
  if (rb) rb.addEventListener('click', () => renameNode(n.id, n.alias));
  const dbtn = $('#del-btn');
  if (dbtn) dbtn.addEventListener('click', () => deleteNode(n.id, n.alias || n.id));
  loadChart(n.id);
}

async function deleteNode(id, name) {
  if (!confirm(`确定从面板删除「${name}」？\n只会移除面板记录，节点上的 Agent 仍在运行。`)) return;
  try {
    await api('/api/nodes/' + encodeURIComponent(id), { method: 'DELETE' });
    toast('节点已移除', 'ok');
    location.hash = '#/fleet';
    route(true);
  } catch (ex) { toast(ex.message, 'err'); }
}

async function toggleModule(id, key, val) {
  const mod = key.replace('enable_', '');
  try {
    await api('/api/nodes/' + encodeURIComponent(id) + '/toggle', {
      method: 'POST', body: JSON.stringify({ mod, state: !!val }),
    });
    toast((val ? '已开启 ' : '已关闭 ') + mod, 'ok');
  } catch (ex) {
    const box = document.querySelector(`[data-toggle="${key}"]`);
    if (box) box.checked = !val;
    toast('切换失败：' + ex.message, 'err');
  }
}

async function renameNode(id, oldName) {
  const alias = prompt('新的节点别名（1~20 个字符）', oldName || '');
  if (!alias) return;
  try {
    await api('/api/nodes/' + encodeURIComponent(id) + '/rename', {
      method: 'POST', body: JSON.stringify({ alias: alias.trim() }),
    });
    toast('别名已更新', 'ok');
    route(true);
  } catch (ex) { toast(ex.message, 'err'); }
}

async function loadChart(id) {
  try {
    const { trend } = await api('/api/nodes/' + encodeURIComponent(id) + '/trend');
    const wrap = $('#chart-wrap');
    if (!wrap) return;
    if (!trend.length) return;
    wrap.innerHTML = svgChart(trend);
  } catch (_) { /* 忽略 */ }
}

function svgChart(rows) {
  const w = 720, h = 220, pad = { l: 34, r: 14, t: 16, b: 26 };
  const pts = rows.filter((r) => typeof r.score === 'number');
  if (!pts.length) return '<div class="empty">暂无评分数据</div>';
  const step = pts.length > 1 ? (w - pad.l - pad.r) / (pts.length - 1) : 0;
  const y = (v) => pad.t + (100 - v) / 100 * (h - pad.t - pad.b);
  const line = pts.map((p, i) => `${pad.l + i * step},${y(p.score)}`).join(' ');
  const area = `${pad.l},${h - pad.b} ${line} ${pad.l + (pts.length - 1) * step},${h - pad.b}`;
  const grid = [0, 25, 50, 75, 100].map((v) => `
    <line x1="${pad.l}" y1="${y(v)}" x2="${w - pad.r}" y2="${y(v)}"
          stroke="rgba(148,163,184,.14)" stroke-dasharray="3 4"/>
    <text x="6" y="${y(v) + 4}" fill="#7c8ba3" font-size="10">${v}</text>`).join('');
  const dots = pts.map((p, i) => `<circle cx="${pad.l + i * step}" cy="${y(p.score)}" r="3" fill="#22d3ee"/>`).join('');
  return `<svg class="chart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
    <defs><linearGradient id="ag" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="rgba(34,211,238,.30)"/><stop offset="1" stop-color="rgba(34,211,238,0)"/>
    </linearGradient></defs>
    ${grid}
    <polygon points="${area}" fill="url(#ag)"/>
    <polyline points="${line}" fill="none" stroke="#22d3ee" stroke-width="2.2" stroke-linejoin="round"/>
    ${dots}
  </svg>`;
}

/* ---------------- 审计 ---------------- */
async function renderAudit() {
  const { commands } = await api('/api/commands');
  view.innerHTML = `
    <div class="section-head"><h2>命令审计</h2><div class="spacer"></div>
      <span class="tag mute">最近 60 条</span></div>
    <div class="card panel" style="padding:8px 4px">
      ${commands.length ? `<table class="table">
        <thead><tr><th>时间</th><th>节点</th><th>动作</th><th>状态</th><th>返回</th></tr></thead>
        <tbody>${commands.map((c) => `
          <tr>
            <td data-label="时间" class="mono">${esc(fmtTime(c.created_at))}</td>
            <td data-label="节点" class="mono">${esc(c.node_id)}</td>
            <td data-label="动作">${esc(c.action)}</td>
            <td data-label="状态"><span class="badge ${esc(c.status)}">${esc(c.status)}</span></td>
            <td data-label="返回" class="mono">${esc((c.output || '').slice(0, 40))}${c.http_code != null ? ' [' + esc(c.http_code) + ']' : ''}</td>
          </tr>`).join('')}</tbody>
      </table>` : '<div class="empty">还没有下发过命令</div>'}
    </div>`;
}

/* ---------------- 设置 ---------------- */
async function renderSettings() {
  const [{ nodes }, { settings }] = await Promise.all([
    api('/api/nodes'), api('/api/settings'),
  ]);
  view.innerHTML = `
    <div class="section-head"><h2>设置</h2></div>

    <div class="card panel" style="max-width:560px">
      <h3>修改登录口令</h3>
      <form id="pw-form" autocomplete="off">
        <label class="field"><span>当前口令</span>
          <input id="pw-old" type="password" autocomplete="current-password" required></label>
        <label class="field"><span>新口令（至少 10 位）</span>
          <input id="pw-new" type="password" autocomplete="new-password" minlength="10" required></label>
        <label class="field"><span>确认新口令</span>
          <input id="pw-confirm" type="password" autocomplete="new-password" minlength="10" required></label>
        <div class="form-error" id="pw-err"></div>
        <button class="btn primary" type="submit">保存新口令</button>
      </form>
      <p class="tip">修改后其他设备的登录状态会立即失效。服务器上的一次性口令文件会被删除。</p>
    </div>

    <div class="card panel" style="max-width:560px">
      <h3>定期质量探针</h3>
      <p class="tip">按周期自动给每台节点抓一次信用图谱，详情页的趋势图才有数据点。设置存在数据库，重启和升级都不会丢。</p>
      <label class="switch"><input type="checkbox" id="probe-enabled" ${settings.probe_enabled === '1' ? 'checked' : ''}> 启用自动采样</label>
      <label class="field" style="margin-top:14px"><span>采样周期</span>
        <select id="probe-interval">
          ${[1, 3, 6, 12, 24].map((h) => `<option value="${h}" ${String(settings.probe_interval_hours) === String(h) ? 'selected' : ''}>每 ${h} 小时</option>`).join('')}
        </select>
      </label>
      <button class="btn primary" id="probe-save">保存采样设置</button>
      <p class="tip" id="probe-hint">当前：${settings.probe_enabled === '1' ? '已启用' : '已暂停'} · 每 ${esc(settings.probe_interval_hours)} 小时</p>
    </div>

    <div class="card panel" style="max-width:560px">
      <h3>系统信息</h3>
      <div class="kv"><span>面板版本</span><b>0.2</b></div>
      <div class="kv"><span>纳管节点</span><b>${nodes.length}</b></div>
      <div class="kv"><span>主控主机</span><b>va01</b></div>
    </div>
  `;

  $('#pw-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const err = $('#pw-err');
    const old = $('#pw-old').value;
    const nw = $('#pw-new').value;
    const cf = $('#pw-confirm').value;
    err.textContent = '';
    if (nw !== cf) { err.textContent = '两次输入的新口令不一致'; return; }
    if (nw.length < 10) { err.textContent = '新口令至少 10 位'; return; }
    const btn = e.target.querySelector('button');
    btn.disabled = true; btn.textContent = '保存中…';
    try {
      await api('/api/password', { method: 'POST', body: JSON.stringify({ old, new: nw }) });
      e.target.reset();
      toast('口令已更新', 'ok');
    } catch (ex) {
      err.textContent = ex.message;
    } finally {
      btn.disabled = false; btn.textContent = '保存新口令';
    }
  });

  const probeSave = $('#probe-save');
  if (probeSave) {
    probeSave.addEventListener('click', async () => {
      const enabled = $('#probe-enabled').checked;
      const hours = Number($('#probe-interval').value);
      probeSave.disabled = true;
      try {
        const r = await api('/api/settings', {
          method: 'POST',
          body: JSON.stringify({ probe_enabled: enabled, probe_interval_hours: hours }),
        });
        const s = r.settings || {};
        $('#probe-hint').textContent = `当前：${s.probe_enabled === '1' ? '已启用' : '已暂停'} · 每 ${s.probe_interval_hours} 小时`;
        toast('采样设置已保存，下一轮按新周期执行', 'ok');
      } catch (ex) {
        toast(ex.message, 'err');
      } finally {
        probeSave.disabled = false;
      }
    });
  }
}

/* ---------------- 交互绑定 ---------------- */
function bindCommon() {
  $$('[data-act]').forEach((btn) => {
    btn.addEventListener('click', () => doAction(btn.dataset.id, btn.dataset.act, btn));
  });
  $$('#quick-add').forEach((b) => b.addEventListener('click', addNodeModal));
  $$('#quick-add-2').forEach((b) => b.addEventListener('click', addNodeModal));
  $$('[data-approve]').forEach((b) => b.addEventListener('click', () => decideNode(b.dataset.approve, true)));
  $$('[data-reject]').forEach((b) => b.addEventListener('click', () => decideNode(b.dataset.reject, false)));
}

async function doAction(id, action, btn) {
  if (action === 'ota' && !confirm('确定让该节点从 GitHub 拉取最新代码并热重载？\n期间服务会短暂中断。')) return;
  const old = btn.textContent;
  btn.disabled = true; btn.textContent = '下发中…';
  try {
    if (action === 'log') {
      toast('正在拉取日志…');
      const { log } = await api('/api/nodes/' + encodeURIComponent(id) + '/log');
      const box = $('#log-box');
      if (box) { box.textContent = log; box.scrollTop = box.scrollHeight; }
      else toast('日志已回传，请进入详情查看');
    } else {
      await api('/api/nodes/' + encodeURIComponent(id) + '/action', {
        method: 'POST', body: JSON.stringify({ action }),
      });
      toast('指令已下发：' + action, 'ok');
    }
  } catch (ex) {
    toast(ex.message, 'err');
  } finally {
    btn.disabled = false; btn.textContent = old;
  }
}

function addNodeModal() {
  const mask = document.createElement('div');
  mask.className = 'modal-mask';
  mask.innerHTML = `
    <div class="modal">
      <h3>添加节点</h3>
      <label class="field"><span>节点 ID</span><input id="m-id" placeholder="如 us-ashburn-01"></label>
      <label class="field"><span>公网 IP</span><input id="m-ip" placeholder="1.2.3.4"></label>
      <label class="field"><span>端口</span><input id="m-port" value="9527"></label>
      <label class="field"><span>PSK（Agent 的 CHAT_ID）</span><input id="m-psk" placeholder="32 位随机串"></label>
      <label class="field"><span>战区</span><input id="m-region" placeholder="United States - Virginia (Ashburn)"></label>
      <div class="modal-actions">
        <button class="btn ghost" id="m-cancel">取消</button>
        <button class="btn primary" id="m-ok">添加</button>
      </div>
    </div>`;
  document.body.appendChild(mask);
  const close = () => mask.remove();
  $('#m-cancel', mask).addEventListener('click', close);
  mask.addEventListener('click', (e) => { if (e.target === mask) close(); });
  $('#m-ok', mask).addEventListener('click', async () => {
    try {
      await api('/api/nodes', {
        method: 'POST',
        body: JSON.stringify({
          id: $('#m-id', mask).value.trim(),
          ip: $('#m-ip', mask).value.trim(),
          port: Number($('#m-port', mask).value || 9527),
          psk: $('#m-psk', mask).value.trim(),
          region: $('#m-region', mask).value.trim(),
          alias: $('#m-id', mask).value.trim(),
        }),
      });
      close(); toast('节点已添加', 'ok'); route(true);
    } catch (ex) { toast(ex.message, 'err'); }
  });
}

function updateSide(online, total) {
  const dot = $('#side-dot'), text = $('#side-text');
  if (!dot) return;
  dot.className = 'dot ' + (total === 0 ? '' : online === total ? 'ok' : online ? 'warn' : 'bad');
  text.textContent = total ? `${online}/${total} 在线` : '无节点';
}

/* ---------------- 启动 ---------------- */
(async function boot() {
  // 清掉历史遗留的旧 Service Worker：本域名在面板上线前曾落到 Sub-Store
  // 默认站点，Sub-Store 的 PWA 在同一个 origin 注册过 /sw.js，会一直用缓存
  // 返回 Sub-Store 的壳。这里对已有注册强制 update()，服务端的 sw.js 是
  // 自杀式清理脚本，激活后会删缓存并注销自己。正常情况下没有注册，啥也不做。
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.getRegistrations()
      .then((rs) => Promise.all(rs.map((r) => r.update().catch(() => {}))))
      .catch(() => {});
  }

  try {
    await api('/api/me');
    showApp();
  } catch (_) {
    showLogin();
  }
})();
