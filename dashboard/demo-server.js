// DBADash demo server — serves the dashboard UI with realistic FAKE data so you
// can preview the full experience without a SQL Server behind it.
//   node dashboard/demo-server.js   ->  http://localhost:8099
// Production uses dashboard\Start-Dashboard.ps1 (PowerShell + the real DBADash
// database); this file exists only for demos/screenshots and requires Node.
const http = require('http');
const fs = require('fs');
const path = require('path');
const WWW = path.join(__dirname, 'www');
const TYPES = { '.html':'text/html', '.css':'text/css', '.js':'application/javascript' };

let owners = [
  { AppOwnerID:1, ServerName:'SQLPROD01\\AG', DatabaseName:'SalesDB', AppName:'Sales Order Portal', Criticality:'Tier1', PrimaryOwner:'Priya Nair', SecondaryOwner:'Sam Cole', Team:'Commerce Platform', Email:'commerce-oncall@corp.com', OnCallPhone:'+1-555-0101', Notes:'PCI in scope' },
  { AppOwnerID:2, ServerName:'SQLPROD03', DatabaseName:'FinanceDB', AppName:'GL Consolidation', Criticality:'Tier1', PrimaryOwner:'Marco Diaz', SecondaryOwner:null, Team:'Finance Systems', Email:'fin-sys@corp.com', OnCallPhone:'+1-555-0144', Notes:null },
  { AppOwnerID:3, ServerName:'rs-analytics', DatabaseName:'(instance)', AppName:'Exec Analytics', Criticality:'Tier2', PrimaryOwner:'Lena Park', SecondaryOwner:'Omar Reed', Team:'Data & Insights', Email:'data-team@corp.com', OnCallPhone:'+1-555-0199', Notes:'Nightly ETL 02:00 UTC' },
];

let servers = [
  { ServerID:1, ServerName:'SQLPROD01\\AG', Platform:'MSSQL', Environment:'PROD', FriendlyName:'Sales AG Primary', IsActive:true, LastCollectedAt:new Date(Date.now()-9e5).toISOString().slice(0,19), LastStatus:'OK', LastMessage:'AG=4 Disk=2 Lag=2' },
  { ServerID:2, ServerName:'SQLPROD02\\AG', Platform:'MSSQL', Environment:'PROD', FriendlyName:'Sales AG Secondary', IsActive:true, LastCollectedAt:new Date(Date.now()-9e5).toISOString().slice(0,19), LastStatus:'OK', LastMessage:'AG=4 Disk=2' },
  { ServerID:3, ServerName:'SQLPROD03', Platform:'MSSQL', Environment:'PROD', FriendlyName:'Finance Standalone', IsActive:true, LastCollectedAt:new Date(Date.now()-9e5).toISOString().slice(0,19), LastStatus:'ERROR', LastMessage:'Login timeout expired' },
  { ServerID:4, ServerName:'rs-analytics', Platform:'Redshift', Environment:'PROD', FriendlyName:'Analytics Cluster', IsActive:true, LastCollectedAt:new Date(Date.now()-9e5).toISOString().slice(0,19), LastStatus:'OK', LastMessage:'Disk=1 Fresh=8' },
  { ServerID:5, ServerName:'SQLUAT01', Platform:'MSSQL', Environment:'UAT', FriendlyName:'UAT box', IsActive:false, LastCollectedAt:null, LastStatus:null, LastMessage:null },
];

const DATA = {
  '/api/servers': () => [...servers].sort((a,b)=>(b.IsActive-a.IsActive)||a.ServerName.localeCompare(b.ServerName)),
  '/api/overview': () => [{ Servers:4, MSSQLServers:3, RedshiftClusters:1, AGDatabases:2, AGUnhealthy:1, LagObjectsCrit:2, DisksCrit:1, DisksWarn:1, BackupsAtRisk:3, JobFailures24h:2, BlockedSessions:3, AppsWithoutOwner:1, LastCollection:new Date().toISOString().slice(0,19) }],
  '/api/backups': () => [
    { Status:'CRIT', ServerName:'SQLPROD03', DatabaseName:'FinanceDB', StateDesc:'ONLINE', RecoveryModel:'FULL', LastFullBackup:new Date(Date.now()-9*864e5).toISOString().slice(0,19), HoursSinceFull:216, LastLogBackup:new Date(Date.now()-9*36e5).toISOString().slice(0,19), LastGoodCheckDb:new Date(Date.now()-45*864e5).toISOString().slice(0,19) },
    { Status:'CRIT', ServerName:'SQLPROD03', DatabaseName:'OldAppDB', StateDesc:'OFFLINE', RecoveryModel:'SIMPLE', LastFullBackup:new Date(Date.now()-40*864e5).toISOString().slice(0,19), HoursSinceFull:960, LastLogBackup:null, LastGoodCheckDb:null },
    { Status:'WARN', ServerName:'SQLPROD03', DatabaseName:'StagingDB', StateDesc:'ONLINE', RecoveryModel:'SIMPLE', LastFullBackup:new Date(Date.now()-3*864e5).toISOString().slice(0,19), HoursSinceFull:72, LastLogBackup:null, LastGoodCheckDb:null },
    { Status:'OK', ServerName:'SQLPROD01\\AG', DatabaseName:'SalesDB', StateDesc:'ONLINE', RecoveryModel:'FULL', LastFullBackup:new Date(Date.now()-6*36e5).toISOString().slice(0,19), HoursSinceFull:6, LastLogBackup:new Date(Date.now()-12*6e4).toISOString().slice(0,19), LastGoodCheckDb:new Date(Date.now()-3*864e5).toISOString().slice(0,19) },
  ],
  '/api/jobs': () => [
    { ServerName:'SQLPROD01\\AG', JobName:'IndexOptimize - USER_DATABASES', StepName:'IndexOptimize', RunAt:new Date(Date.now()-3*36e5).toISOString().slice(0,19), Message:'Lock request time out period exceeded. The step failed.' },
    { ServerName:'SQLPROD03', JobName:'Nightly ETL - Finance', StepName:'Load GL', RunAt:new Date(Date.now()-7*36e5).toISOString().slice(0,19), Message:'Violation of PRIMARY KEY constraint PK_GL. The step failed.' },
  ],
  '/api/vitals': () => [
    { Status:'CRIT', Platform:'MSSQL', ServerName:'SQLPROD03', MetricName:'blocked_sessions', MetricValue:3 },
    { Status:'WARN', Platform:'MSSQL', ServerName:'SQLPROD03', MetricName:'page_life_expectancy', MetricValue:180 },
    { Status:'WARN', Platform:'Redshift', ServerName:'rs-analytics', MetricName:'queued_queries', MetricValue:4 },
    { Status:'WARN', Platform:'Redshift', ServerName:'rs-analytics', MetricName:'load_errors_24h', MetricValue:2 },
    { Status:'OK', Platform:'MSSQL', ServerName:'SQLPROD01\\AG', MetricName:'page_life_expectancy', MetricValue:4200 },
    { Status:'OK', Platform:'MSSQL', ServerName:'SQLPROD01\\AG', MetricName:'user_sessions', MetricValue:134 },
  ],
  '/api/activity': () => [
    { RowStatus:'CRIT', Platform:'MSSQL', ServerName:'SQLPROD03', SessionID:74, BlockedBy:51, Status:'suspended', WaitType:'LCK_M_X', DurationSec:312, DatabaseName:'FinanceDB', LoginName:'app_finance', QueryText:'UPDATE dbo.GLEntries SET Posted=1 WHERE BatchID=@b' },
    { RowStatus:'CRIT', Platform:'MSSQL', ServerName:'SQLPROD03', SessionID:88, BlockedBy:51, Status:'suspended', WaitType:'LCK_M_S', DurationSec:285, DatabaseName:'FinanceDB', LoginName:'report_svc', QueryText:'SELECT SUM(Amount) FROM dbo.GLEntries WHERE ...' },
    { RowStatus:'WARN', Platform:'MSSQL', ServerName:'SQLPROD03', SessionID:51, BlockedBy:0, Status:'running', WaitType:null, DurationSec:745, DatabaseName:'FinanceDB', LoginName:'etl_svc', QueryText:'BEGIN TRAN; DELETE FROM dbo.GLEntries WHERE Period=...' },
    { RowStatus:'WARN', Platform:'Redshift', ServerName:'rs-analytics', SessionID:1201, BlockedBy:0, Status:'Running', WaitType:null, DurationSec:1520, DatabaseName:'analytics', LoginName:'etl_user', QueryText:'INSERT INTO fact_sales SELECT * FROM staging_sales ...' },
  ],
  '/api/waits': () => [
    { ServerName:'SQLPROD03', WaitType:'LCK_M_X', WaitTimeMs:9800000, WaitPct:41.2 },
    { ServerName:'SQLPROD03', WaitType:'PAGEIOLATCH_SH', WaitTimeMs:6200000, WaitPct:26.1 },
    { ServerName:'SQLPROD03', WaitType:'CXPACKET', WaitTimeMs:3100000, WaitPct:13.0 },
    { ServerName:'SQLPROD01\\AG', WaitType:'HADR_SYNC_COMMIT', WaitTimeMs:4200000, WaitPct:33.5 },
  ],
  '/api/tablehealth': () => [
    { Status:'CRIT', ServerName:'rs-analytics', TableName:'public.fact_sales', UnsortedPct:62.4, StatsOffPct:18.0, TableRows:4820000000 },
    { Status:'WARN', ServerName:'rs-analytics', TableName:'public.stg_events', UnsortedPct:35.1, StatsOffPct:44.9, TableRows:91000000 },
    { Status:'WARN', ServerName:'rs-analytics', TableName:'public.dim_customer', UnsortedPct:12.2, StatsOffPct:21.5, TableRows:18000000 },
  ],
  '/api/ag': () => [
    { Status:'CRIT', AGName:'SalesAG', DatabaseName:'OrdersDB', ReplicaServer:'SQLPROD02\\AG', Role:'SECONDARY', SyncState:'SYNCHRONIZING', SyncHealth:'PARTIALLY_HEALTHY', LogSendQueueKB:85000, RedoQueueKB:120000 },
    { Status:'OK', AGName:'SalesAG', DatabaseName:'SalesDB', ReplicaServer:'SQLPROD01\\AG', Role:'PRIMARY', SyncState:'SYNCHRONIZED', SyncHealth:'HEALTHY', LogSendQueueKB:0, RedoQueueKB:0 },
    { Status:'OK', AGName:'SalesAG', DatabaseName:'SalesDB', ReplicaServer:'SQLPROD02\\AG', Role:'SECONDARY', SyncState:'SYNCHRONIZED', SyncHealth:'HEALTHY', LogSendQueueKB:12, RedoQueueKB:40 },
  ],
  '/api/lag': () => [
    { Status:'CRIT', Platform:'Redshift', ServerName:'rs-analytics', ObjectName:'public.dim_customer', Metric:'load_freshness', LagSeconds:5400, Detail:'last load 90 min ago' },
    { Status:'WARN', Platform:'MSSQL', ServerName:'SQLPROD01\\AG', ObjectName:'AG:OrdersDB@SQLPROD02\\AG', Metric:'ag_redo_lag', LagSeconds:420, Detail:'AG=SalesAG; RedoQueueKB=120000' },
    { Status:'OK', Platform:'MSSQL', ServerName:'SQLPROD01\\AG', ObjectName:'AG:SalesDB@SQLPROD02\\AG', Metric:'ag_redo_lag', LagSeconds:3, Detail:'AG=SalesAG; RedoQueueKB=40' },
  ],
  '/api/disk': () => [
    { Severity:'CRIT', Platform:'MSSQL', ServerName:'SQLPROD03', VolumeName:'F:\\', UsedGB:1030.0, TotalGB:1024.0*1, UsedPct:96.5, GrowthGBPerDay:10.2, DaysToFull:9, ProjectedFullDate:'2026-07-16', RecommendedAddGB:1836 },
    { Severity:'WARN', Platform:'Redshift', ServerName:'rs-analytics', VolumeName:'cluster', UsedGB:8100.0, TotalGB:10240.0, UsedPct:79.1, GrowthGBPerDay:83.8, DaysToFull:25, ProjectedFullDate:'2026-08-01', RecommendedAddGB:14730 },
    { Severity:'OK', Platform:'MSSQL', ServerName:'SQLPROD03', VolumeName:'C:\\', UsedGB:111.8, TotalGB:250.0, UsedPct:44.7, GrowthGBPerDay:null, DaysToFull:null, ProjectedFullDate:null, RecommendedAddGB:null },
  ],
  '/api/owners': () => owners,
  '/api/growthkeys': () => [
    { Platform:'MSSQL', ServerName:'SQLPROD03', ObjectType:'database', ObjectName:'FinanceDB', CurrentGB:276.0, DeltaGB:156.0, GrowthGBPerDay:5.2 },
    { Platform:'Redshift', ServerName:'rs-analytics', ObjectType:'table', ObjectName:'public.fact_sales', CurrentGB:2400.0, DeltaGB:1950.0, GrowthGBPerDay:65.0 },
    { Platform:'MSSQL', ServerName:'SQLPROD01\\AG', ObjectType:'database', ObjectName:'SalesDB', CurrentGB:138.0, DeltaGB:63.0, GrowthGBPerDay:2.1 },
  ],
  '/api/cost': () => [
    { Severity:'CRIT', ServerName:'rs-analytics', MetricName:'bytes_scanned_tb_1d', MetricUnit:'TB', ObservedDay:new Date().toISOString().slice(0,10), Value:3.4, Baseline:0.48, ZScore:9.2, PctAboveBaseline:608.3 },
    { Severity:'WARN', ServerName:'rs-analytics', MetricName:'spectrum_tb_1d', MetricUnit:'TB', ObservedDay:new Date().toISOString().slice(0,10), Value:0.9, Baseline:0.11, ZScore:6.8, PctAboveBaseline:718.2 },
  ],
  '/api/costkeys': () => [
    { ServerName:'rs-analytics', MetricName:'bytes_scanned_tb_1d', MetricUnit:'TB' },
    { ServerName:'rs-analytics', MetricName:'spectrum_tb_1d', MetricUnit:'TB' },
    { ServerName:'rs-analytics', MetricName:'storage_gb', MetricUnit:'GB' },
  ],
  '/api/alerts': () => [
    { AlertID:1, Severity:'CRIT', Category:'Disk', ServerName:'SQLPROD03', Message:'SQLPROD03 F:\\ at 96.5% - full in 9 days (add +1836 GB)', Owner:'Marco Diaz', FirstSeen:new Date(Date.now()-3600e3).toISOString().slice(0,19), NotifiedAt:new Date().toISOString().slice(0,19) },
    { AlertID:2, Severity:'CRIT', Category:'Cost', ServerName:'rs-analytics', Message:'Cost spike: bytes_scanned_tb_1d = 3.4 (608.3% over baseline)', Owner:'Lena Park', FirstSeen:new Date(Date.now()-1800e3).toISOString().slice(0,19), NotifiedAt:null },
    { AlertID:3, Severity:'WARN', Category:'Lag', ServerName:'SQLPROD01\\AG', Message:'MSSQL AG:OrdersDB@SQLPROD02\\AG lag = 420s', Owner:'Priya Nair', FirstSeen:new Date(Date.now()-600e3).toISOString().slice(0,19), NotifiedAt:null },
  ],
};

// growth series: generate N days trending up for the requested object
function growthSeries(url){
  const q = new URL('http://x'+url).searchParams;
  const obj = q.get('object')||'';
  const base = obj.includes('fact_sales')?450:obj.includes('FinanceDB')?120:75;
  const rate = obj.includes('fact_sales')?65:obj.includes('FinanceDB')?5.2:2.1;
  const days=30, out=[];
  for(let i=days;i>=0;i--){ const d=new Date(Date.now()-i*864e5); out.push({ Day:d.toISOString().slice(0,10), SizeGB:+(base+(days-i)*rate).toFixed(1) }); }
  return out;
}

function body(req){return new Promise(r=>{let b='';req.on('data',c=>b+=c);req.on('end',()=>r(b));});}

http.createServer(async (req,res)=>{
  const url = req.url.replace(/\/$/,'');
  if (req.method==='POST' && url==='/api/owners') {
    const o = JSON.parse(await body(req)); o.AppOwnerID=Number(o.AppOwnerID)||0;
    if(o.AppOwnerID) owners=owners.map(x=>x.AppOwnerID===o.AppOwnerID?{...x,...o}:x);
    else { o.AppOwnerID=Math.max(0,...owners.map(x=>x.AppOwnerID))+1; owners.push(o); }
    res.setHeader('Content-Type','application/json'); return res.end('{"ok":true}');
  }
  if (req.method==='POST' && url==='/api/servers') {
    const o = JSON.parse(await body(req));
    const ex = servers.find(x=>x.ServerName===o.ServerName);
    if (ex) Object.assign(ex, o);
    else servers.push({ ServerID:Math.max(0,...servers.map(x=>x.ServerID))+1, LastCollectedAt:null, LastStatus:null, LastMessage:null, ...o });
    res.setHeader('Content-Type','application/json'); return res.end('{"ok":true}');
  }
  if (req.method==='POST' && url==='/api/servers/delete') {
    const o = JSON.parse(await body(req)); servers=servers.filter(x=>x.ServerID!==Number(o.ServerID));
    res.setHeader('Content-Type','application/json'); return res.end('{"ok":true}');
  }
  if (req.method==='POST' && url==='/api/owners/delete') {
    const o = JSON.parse(await body(req)); owners=owners.filter(x=>x.AppOwnerID!==Number(o.AppOwnerID));
    res.setHeader('Content-Type','application/json'); return res.end('{"ok":true}');
  }
  if (url.startsWith('/api/growth?') || url==='/api/growth') { res.setHeader('Content-Type','application/json'); return res.end(JSON.stringify(growthSeries(req.url))); }
  if (url.startsWith('/api/costtrend')) {
    const q = new URL('http://x'+req.url).searchParams, m = q.get('metric')||'';
    // 15-day baseline with a spike today for the scan metrics; steady climb for storage
    const out = [];
    for (let i=15;i>=0;i--){
      const d = new Date(Date.now()-i*864e5).toISOString().slice(0,10);
      let v;
      if (m==='storage_gb') v = 6000+(15-i)*90;
      else if (m==='spectrum_tb_1d') v = i===0?0.9:+(0.10+((i%2)*0.02)).toFixed(2);
      else v = i===0?3.4:+(0.45+((i%3)*0.05)).toFixed(2);
      out.push({ Day:d, Value:v, MetricUnit:m==='storage_gb'?'GB':'TB' });
    }
    res.setHeader('Content-Type','application/json'); return res.end(JSON.stringify(out));
  }
  if (DATA[url]) { res.setHeader('Content-Type','application/json'); return res.end(JSON.stringify(DATA[url]())); }
  let rel = url===''?'index.html':url.slice(1);
  const file = path.join(WWW, rel);
  if (fs.existsSync(file)) { res.setHeader('Content-Type', TYPES[path.extname(file)]||'text/plain'); return res.end(fs.readFileSync(file)); }
  res.statusCode=404; res.end('nf');
}).listen(8099, ()=>console.log('mock DBADash on http://localhost:8099'));
