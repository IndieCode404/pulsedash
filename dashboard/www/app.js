/* DBADash front-end — talks to the PowerShell JSON API in Start-Dashboard.ps1 */
'use strict';

const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const api = (p, opt) => fetch(p, opt).then(r => r.json());
const esc = s => (s == null ? '' : String(s)).replace(/[&<>"]/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;' }[c]));
const pill = s => `<span class="pill ${s}">${s}</span>`;
const num  = n => (n == null ? '—' : Number(n).toLocaleString());

function fmtLag(sec) {
  if (sec == null) return '—';
  sec = Number(sec);
  if (sec < 90) return sec + 's';
  if (sec < 5400) return (sec / 60).toFixed(1) + 'm';
  return (sec / 3600).toFixed(1) + 'h';
}

function table(rows, cols) {
  if (!rows || !rows.length) return '<div class="empty">No data yet — run the collector or load the demo seed.</div>';
  const head = '<tr>' + cols.map(c => `<th>${c.h}</th>`).join('') + '</tr>';
  const body = rows.map(r => {
    const sev = r.Status || r.Severity;
    const cls = (sev === 'CRIT' || sev === 'WARN') ? ` class="row-${sev}"` : '';
    return `<tr${cls}>` + cols.map(c => `<td>${c.f ? c.f(r[c.k], r) : esc(r[c.k])}</td>`).join('') + '</tr>';
  }).join('');
  return `<table>${head}${body}</table>`;
}

/* ---- KPI strip ---- */
async function loadKpis() {
  const [o, alerts] = await Promise.all([
    api('/api/overview').then(r => r[0] || {}),
    api('/api/alerts').then(r => r || []).catch(() => []),
  ]);
  const activeAlerts = alerts.length;
  const cards = [
    { lbl: 'Servers',        num: o.Servers,          cls: '' },
    { lbl: 'Active alerts',  num: activeAlerts,       cls: activeAlerts > 0 ? 'crit' : 'ok' },
    { lbl: 'AG unhealthy',   num: o.AGUnhealthy,      cls: o.AGUnhealthy > 0 ? 'crit' : 'ok' },
    { lbl: 'Lag critical',   num: o.LagObjectsCrit,   cls: o.LagObjectsCrit > 0 ? 'crit' : 'ok' },
    { lbl: 'Disks critical', num: o.DisksCrit,        cls: o.DisksCrit > 0 ? 'crit' : 'ok' },
    { lbl: 'Backups at risk',num: o.BackupsAtRisk,    cls: o.BackupsAtRisk > 0 ? 'crit' : 'ok' },
    { lbl: 'Job failures 24h', num: o.JobFailures24h, cls: o.JobFailures24h > 0 ? 'warn' : 'ok' },
    { lbl: 'Blocked sessions', num: o.BlockedSessions, cls: o.BlockedSessions > 0 ? 'crit' : 'ok' },
    { lbl: 'No owner',       num: o.AppsWithoutOwner, cls: o.AppsWithoutOwner > 0 ? 'warn' : 'ok' },
  ];
  $('#kpis').innerHTML = cards.map(c =>
    `<div class="kpi ${c.cls}"><div class="num">${c.num ?? '—'}</div><div class="lbl">${c.lbl}</div></div>`).join('');
  $('#lastRun').textContent = o.LastCollection ? 'last collection: ' + new Date(o.LastCollection + 'Z').toLocaleString() : 'no collections yet';
}

/* ---- tabs ---- */
async function loadAg() {
  const rows = await api('/api/ag');
  $('#agTable').innerHTML = table(rows, [
    { h: 'Status',   k: 'Status', f: pill },
    { h: 'AG',       k: 'AGName' },
    { h: 'Database', k: 'DatabaseName' },
    { h: 'Replica',  k: 'ReplicaServer' },
    { h: 'Role',     k: 'Role' },
    { h: 'Sync state', k: 'SyncState' },
    { h: 'Health',   k: 'SyncHealth' },
    { h: 'Send Q (KB)', k: 'LogSendQueueKB', f: num },
    { h: 'Redo Q (KB)', k: 'RedoQueueKB',    f: num },
  ]);
}

async function loadLag() {
  const rows = await api('/api/lag');
  $('#lagTable').innerHTML = table(rows, [
    { h: 'Status',   k: 'Status', f: pill },
    { h: 'Platform', k: 'Platform' },
    { h: 'Server',   k: 'ServerName' },
    { h: 'Object',   k: 'ObjectName' },
    { h: 'Metric',   k: 'Metric' },
    { h: 'Lag',      k: 'LagSeconds', f: fmtLag },
    { h: 'Detail',   k: 'Detail' },
  ]);
}

async function loadDisk() {
  const rows = await api('/api/disk');
  $('#diskTable').innerHTML = table(rows, [
    { h: 'Severity', k: 'Severity', f: pill },
    { h: 'Platform', k: 'Platform' },
    { h: 'Server',   k: 'ServerName' },
    { h: 'Volume',   k: 'VolumeName' },
    { h: 'Used', k: 'UsedPct', f: (v, r) => {
        const p = Number(v) || 0, cls = p >= 90 ? 'crit' : p >= 75 ? 'warn' : '';
        return `<span class="bar ${cls}"><i style="width:${Math.min(p,100)}%"></i></span>${p}% <span class="muted">(${r.UsedGB}/${r.TotalGB} GB)</span>`;
      } },
    { h: 'Growth/day', k: 'GrowthGBPerDay', f: v => v == null ? '—' : v + ' GB' },
    { h: 'Days to full', k: 'DaysToFull', f: v => v == null ? '∞' : v },
    { h: 'Projected full', k: 'ProjectedFullDate', f: v => v ? String(v).slice(0,10) : '—' },
    { h: 'Add', k: 'RecommendedAddGB', f: v => v == null ? '—' : `+${v} GB` },
  ]);
}

async function loadOwners() {
  const rows = await api('/api/owners');
  $('#ownersTable').innerHTML = table(rows, [
    { h: 'Tier',    k: 'Criticality', f: v => `<span class="tier ${v}">${v}</span>` },
    { h: 'Server',  k: 'ServerName' },
    { h: 'Database',k: 'DatabaseName' },
    { h: 'App',     k: 'AppName' },
    { h: 'Primary', k: 'PrimaryOwner' },
    { h: 'Secondary', k: 'SecondaryOwner' },
    { h: 'Team',    k: 'Team' },
    { h: 'Email',   k: 'Email', f: v => v ? `<a class="link" href="mailto:${esc(v)}">${esc(v)}</a>` : '—' },
    { h: 'On-call', k: 'OnCallPhone' },
    { h: '', k: 'AppOwnerID', f: (v, r) =>
        `<span class="link" onclick='editOwner(${JSON.stringify(r).replace(/'/g,"&#39;")})'>edit</span> ·
         <span class="link danger" onclick="delOwner(${v})">del</span>` },
  ]);
}

/* ---- health tab (backups + job failures) ---- */
const fmtDt = v => v ? new Date(v + 'Z').toLocaleString() : 'NEVER';
const ago = v => v == null ? '—' : v;

async function loadHealth() {
  const [backups, jobs] = await Promise.all([api('/api/backups'), api('/api/jobs')]);
  $('#backupsTable').innerHTML = table(backups, [
    { h: 'Status',   k: 'Status', f: pill },
    { h: 'Server',   k: 'ServerName' },
    { h: 'Database', k: 'DatabaseName' },
    { h: 'State',    k: 'StateDesc' },
    { h: 'Recovery', k: 'RecoveryModel' },
    { h: 'Last full', k: 'LastFullBackup', f: fmtDt },
    { h: 'Hrs since full', k: 'HoursSinceFull', f: ago },
    { h: 'Last log', k: 'LastLogBackup', f: (v, r) => r.RecoveryModel === 'SIMPLE' ? 'n/a' : fmtDt(v) },
    { h: 'Last good CHECKDB', k: 'LastGoodCheckDb', f: fmtDt },
  ]);
  $('#jobsTable').innerHTML = table(jobs, [
    { h: 'Server', k: 'ServerName' },
    { h: 'Job',    k: 'JobName' },
    { h: 'Step',   k: 'StepName' },
    { h: 'Failed at', k: 'RunAt', f: fmtDt },
    { h: 'Message', k: 'Message', f: v => `<span title="${esc(v)}">${esc((v || '').slice(0, 90))}${(v||'').length > 90 ? '…' : ''}</span>` },
  ]);
}

/* ---- activity tab (vitals + queries + waits + redshift table health) ---- */
const VITAL_LABELS = {
  page_life_expectancy: 'Page life expectancy (s)', memory_grants_pending: 'Memory grants pending',
  user_sessions: 'User sessions', blocked_sessions: 'Blocked sessions', uptime_hours: 'Uptime (h)',
  queued_queries: 'Queued queries (WLM)', db_connections: 'Connections', load_errors_24h: 'Load errors (24h)',
};

async function loadActivity() {
  const [vitals, act, waits, thl] = await Promise.all([
    api('/api/vitals'), api('/api/activity'), api('/api/waits'), api('/api/tablehealth')]);
  $('#vitalsTable').innerHTML = table(vitals, [
    { h: 'Status',  k: 'Status', f: pill },
    { h: 'Platform',k: 'Platform' },
    { h: 'Server',  k: 'ServerName' },
    { h: 'Metric',  k: 'MetricName', f: v => VITAL_LABELS[v] || v },
    { h: 'Value',   k: 'MetricValue', f: num },
  ]);
  $('#activityTable').innerHTML = table(
    act.map(r => ({ ...r, Status: r.RowStatus })),   // reuse row highlighting
    [
      { h: 'Status',  k: 'Status', f: pill },
      { h: 'Platform',k: 'Platform' },
      { h: 'Server',  k: 'ServerName' },
      { h: 'Session', k: 'SessionID' },
      { h: 'Blocked by', k: 'BlockedBy', f: v => v ? `<b>${v}</b>` : '—' },
      { h: 'Wait',    k: 'WaitType' },
      { h: 'Duration',k: 'DurationSec', f: fmtLag },
      { h: 'Database',k: 'DatabaseName' },
      { h: 'Login',   k: 'LoginName' },
      { h: 'Query',   k: 'QueryText', f: v => `<span title="${esc(v)}">${esc((v || '').slice(0, 70))}${(v||'').length > 70 ? '…' : ''}</span>` },
    ]);
  $('#waitsTable').innerHTML = table(waits, [
    { h: 'Server',   k: 'ServerName' },
    { h: 'Wait type',k: 'WaitType' },
    { h: 'Wait time (ms)', k: 'WaitTimeMs', f: num },
    { h: '% of waits', k: 'WaitPct', f: v => v == null ? '—' : `<span class="bar${v >= 40 ? ' warn' : ''}"><i style="width:${Math.min(v,100)}%"></i></span>${v}%` },
  ]);
  $('#tableHealthTable').innerHTML = table(thl, [
    { h: 'Status',  k: 'Status', f: pill },
    { h: 'Cluster', k: 'ServerName' },
    { h: 'Table',   k: 'TableName' },
    { h: 'Unsorted %', k: 'UnsortedPct', f: v => v + '%' },
    { h: 'Stats off %', k: 'StatsOffPct', f: v => v + '%' },
    { h: 'Rows',    k: 'TableRows', f: num },
  ]);
}

/* ---- growth (SVG line chart, no chart library) ---- */
function lineChart(points, unit, key = 'SizeGB') {
  if (!points || points.length < 2) return '<div class="empty">Not enough history yet — needs at least 2 days of collections.</div>';
  const W = 900, H = 300, pad = { l: 56, r: 20, t: 16, b: 28 };
  const xs = points.map((_, i) => i), ys = points.map(p => Number(p[key]));
  const yMin = Math.min(...ys), yMax = Math.max(...ys);
  const yLo = yMin - (yMax - yMin || 1) * 0.1, yHi = yMax + (yMax - yMin || 1) * 0.1;
  const px = i => pad.l + (i / (points.length - 1)) * (W - pad.l - pad.r);
  const py = v => pad.t + (1 - (v - yLo) / (yHi - yLo || 1)) * (H - pad.t - pad.b);
  const line = points.map((p, i) => `${px(i)},${py(ys[i])}`).join(' ');
  const area = `${pad.l},${py(yLo)} ${line} ${px(points.length - 1)},${py(yLo)}`;
  const yticks = [0, .25, .5, .75, 1].map(f => { const v = yLo + f * (yHi - yLo); return { v, y: py(v) }; });
  const step = Math.ceil(points.length / 8);
  const xlabels = points.map((p, i) => ({ i, d: p.Day })).filter((_, i) => i % step === 0);
  const first = ys[0], last = ys[ys.length - 1], delta = (last - first).toFixed(1);
  return `
    <div class="chart-head"><span class="muted">${points.length} days · </span>
      <b>${last.toFixed(1)} ${unit}</b> now ·
      <span class="${delta >= 0 ? 'up' : 'down'}">${delta >= 0 ? '▲' : '▼'} ${Math.abs(delta)} ${unit}</span> over window</div>
    <svg viewBox="0 0 ${W} ${H}" class="linechart" preserveAspectRatio="xMidYMid meet">
      ${yticks.map(t => `<line x1="${pad.l}" y1="${t.y}" x2="${W - pad.r}" y2="${t.y}" class="grid"/>
         <text x="${pad.l - 8}" y="${t.y + 4}" class="ytick">${t.v.toFixed(1)}</text>`).join('')}
      <polygon points="${area}" class="area"/>
      <polyline points="${line}" class="line"/>
      ${points.map((p, i) => `<circle cx="${px(i)}" cy="${py(ys[i])}" r="2.5" class="dot"><title>${p.Day}: ${ys[i]} ${unit}</title></circle>`).join('')}
      ${xlabels.map(l => `<text x="${px(l.i)}" y="${H - 8}" class="xtick">${l.d.slice(5)}</text>`).join('')}
    </svg>`;
}

let growthKeys = [];
async function loadGrowth() {
  growthKeys = await api('/api/growthkeys');
  const sel = $('#growthKey');
  if (!growthKeys.length) { sel.innerHTML = ''; $('#growthChart').innerHTML = '<div class="empty">No size history collected yet.</div>'; $('#growthTable').innerHTML = ''; return; }
  if (!sel.dataset.filled) {
    sel.innerHTML = growthKeys.map((k, i) =>
      `<option value="${i}">${esc(k.Platform)} · ${esc(k.ServerName)} · ${esc(k.ObjectName)} (${k.CurrentGB} GB)</option>`).join('');
    sel.dataset.filled = '1';
  }
  await drawGrowth();
  // top movers table
  $('#growthTable').innerHTML = table(growthKeys, [
    { h: 'Platform', k: 'Platform' },
    { h: 'Server',   k: 'ServerName' },
    { h: 'Object',   k: 'ObjectName' },
    { h: 'Type',     k: 'ObjectType' },
    { h: 'Current',  k: 'CurrentGB', f: v => v + ' GB' },
    { h: 'Δ window', k: 'DeltaGB', f: v => (v >= 0 ? '+' : '') + v + ' GB' },
    { h: 'Growth/day', k: 'GrowthGBPerDay', f: v => v + ' GB' },
  ]);
}

async function drawGrowth() {
  const k = growthKeys[Number($('#growthKey').value) || 0];
  if (!k) return;
  const qs = `platform=${encodeURIComponent(k.Platform)}&server=${encodeURIComponent(k.ServerName)}&object=${encodeURIComponent(k.ObjectName)}`;
  const pts = await api('/api/growth?' + qs);
  $('#growthChart').innerHTML = lineChart(pts, 'GB');
}

let costKeys = [];
async function loadCost() {
  costKeys = await api('/api/costkeys').catch(() => []);
  const sel = $('#costKey');
  if (!costKeys.length) {
    sel.innerHTML = '';
    $('#costChart').innerHTML = '<div class="empty">No cost-driver history collected yet.</div>';
  } else {
    if (!sel.dataset.filled) {
      sel.innerHTML = costKeys.map((k, i) =>
        `<option value="${i}">${esc(k.ServerName)} · ${esc(k.MetricName)}${k.MetricUnit ? ' (' + esc(k.MetricUnit) + ')' : ''}</option>`).join('');
      sel.dataset.filled = '1';
    }
    await drawCostTrend();
  }
  const rows = await api('/api/cost');
  $('#costTable').innerHTML = table(rows, [
    { h: 'Severity', k: 'Severity', f: pill },
    { h: 'Cluster',  k: 'ServerName' },
    { h: 'Metric',   k: 'MetricName' },
    { h: 'Day',      k: 'ObservedDay', f: v => v ? String(v).slice(0,10) : '—' },
    { h: 'Value',    k: 'Value', f: (v, r) => `${v} ${esc(r.MetricUnit || '')}` },
    { h: 'Baseline', k: 'Baseline', f: (v, r) => `${v} ${esc(r.MetricUnit || '')}` },
    { h: 'Z-score',  k: 'ZScore' },
    { h: '% over',   k: 'PctAboveBaseline', f: v => v == null ? '—' : '+' + v + '%' },
  ]);
}

async function drawCostTrend() {
  const k = costKeys[Number($('#costKey').value) || 0];
  if (!k) return;
  const qs = `server=${encodeURIComponent(k.ServerName)}&metric=${encodeURIComponent(k.MetricName)}`;
  const pts = await api('/api/costtrend?' + qs);
  $('#costChart').innerHTML = lineChart(pts, k.MetricUnit || '', 'Value');
}

async function loadAlerts() {
  const rows = await api('/api/alerts');
  $('#alertsTable').innerHTML = table(rows, [
    { h: 'Severity', k: 'Severity', f: pill },
    { h: 'Category', k: 'Category' },
    { h: 'Server',   k: 'ServerName' },
    { h: 'Detail',   k: 'Message' },
    { h: 'Owner',    k: 'Owner' },
    { h: 'Since',    k: 'FirstSeen', f: v => v ? new Date(v + 'Z').toLocaleString() : '—' },
    { h: 'Notified', k: 'NotifiedAt', f: v => v ? '✓' : '—' },
  ]);
}

/* ---- owner form ---- */
const FIELDS = ['AppOwnerID','ServerName','DatabaseName','AppName','Criticality',
                'PrimaryOwner','SecondaryOwner','Team','Email','OnCallPhone','Notes'];

function showForm(show) { $('#ownerForm').classList.toggle('hidden', !show); $('#formMsg').textContent = ''; }
function clearForm() { FIELDS.forEach(f => { const el = $('#f_' + f); if (el) el.value = f === 'AppOwnerID' ? '0' : ''; }); }

window.editOwner = function (r) {
  showForm(true);
  FIELDS.forEach(f => { const el = $('#f_' + f); if (el) el.value = r[f] ?? ''; });
  $('#f_AppOwnerID').value = r.AppOwnerID || 0;
  window.scrollTo({ top: 0, behavior: 'smooth' });
};

window.delOwner = async function (id) {
  if (!confirm('Delete this owner record?')) return;
  await api('/api/owners/delete', { method: 'POST', body: JSON.stringify({ AppOwnerID: id }) });
  loadOwners(); loadKpis();
};

async function saveOwner() {
  const body = {};
  FIELDS.forEach(f => body[f] = $('#f_' + f)?.value ?? '');
  if (!body.ServerName || !body.AppName) { $('#formMsg').textContent = 'Server and App are required.'; return; }
  const res = await api('/api/owners', { method: 'POST', body: JSON.stringify(body) });
  if (res.error) { $('#formMsg').textContent = 'Error: ' + res.error; return; }
  showForm(false); clearForm(); loadOwners(); loadKpis();
}

/* ---- wiring ---- */
function refreshActive() {
  const t = $('.tab.active').dataset.tab;
  ({ ag: loadAg, lag: loadLag, disk: loadDisk, growth: loadGrowth,
     health: loadHealth, activity: loadActivity,
     cost: loadCost, alerts: loadAlerts, owners: loadOwners }[t])();
  loadKpis();
}

$$('.tab').forEach(t => t.addEventListener('click', () => {
  $$('.tab').forEach(x => x.classList.remove('active'));
  $$('.panel').forEach(x => x.classList.remove('active'));
  t.classList.add('active');
  $('#tab-' + t.dataset.tab).classList.add('active');
  refreshActive();
}));

$('#refreshBtn').addEventListener('click', refreshActive);
$('#growthKey').addEventListener('change', drawGrowth);
$('#costKey').addEventListener('change', drawCostTrend);
$('#newOwnerBtn').addEventListener('click', () => { clearForm(); showForm(true); });
$('#cancelOwnerBtn').addEventListener('click', () => showForm(false));
$('#saveOwnerBtn').addEventListener('click', saveOwner);

let timer = null;
function setAuto(on) { clearInterval(timer); if (on) timer = setInterval(refreshActive, 30000); }
$('#autoRefresh').addEventListener('change', e => setAuto(e.target.checked));

loadKpis(); loadAg(); setAuto(true);
