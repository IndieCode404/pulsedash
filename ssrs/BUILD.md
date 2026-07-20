# DBADash on SSRS — build guide

The SSRS version of the estate console: a **landing "Estate Health" matrix** that
drills through to **per-domain detail reports**, plus a **daily morning-email
subscription**. It reads the *same* `rpt.*` views as the HTML dashboard — no new
collection. This is the governance-friendly path: SSRS is already licensed,
Kerberos/AD-secured, and audited in most enterprises.

```
 rpt.EstateHealth  ─▶  01_EstateHealth.rdl   (landing: server × domain, RAG)
        │                        │ drill-through (passes @ServerName)
 rpt.BackupHealth ──┐            ▼
 rpt.DiskForecast ──┤   ServerDetail.rdl  +  per-domain reports
 rpt.AGSyncStatus ──┤   (Backup, Disk, AG, Index, Config, Login, Growth…)
 rpt.IndexHealth  ──┘
```

## 0. Prerequisites
- DBADash central database deployed (so the `rpt.*` views exist) and
  `ssrs\sql\rpt_EstateHealth.sql` run against it.
- SSRS in **Native** or **SharePoint** mode, or Power BI Report Server.
- **Report Builder** (free) or Visual Studio + *SSDT / Microsoft Reporting
  Services Projects* extension.
- The Report Server service account (or a stored credential) with **db_datareader**
  on `DBADash`. Reports are read-only.

## 1. Shared data source — `DBADash`
Report Server → **New → Data Source**
- Type: **Microsoft SQL Server**
- Connection string: `Data Source=SQLMON01;Initial Catalog=DBADash`
- Credentials: *stored* (a read-only login) **or** *Windows integrated* if the
  service account has access. All reports reference this one shared source.

## 2. Shared datasets (reuse across reports)
Create these as **shared datasets** against the `DBADash` source:

| Shared dataset | Query |
|---|---|
| `ds_Estate` | `SELECT * FROM rpt.EstateHealth ORDER BY OverallRank, ServerName` |
| `ds_Backup` | `SELECT * FROM rpt.BackupHealth WHERE ServerName = @ServerName ORDER BY Status` |
| `ds_Disk` | `SELECT * FROM rpt.DiskForecast WHERE ServerName = @ServerName ORDER BY Severity` |
| `ds_AG` | `SELECT * FROM rpt.AGSyncStatus WHERE ReplicaServer = @ServerName` |
| `ds_Index` | `SELECT * FROM rpt.IndexHealth WHERE ServerName = @ServerName` |
| `ds_Config` | `SELECT * FROM rpt.ConfigAudit WHERE ServerName = @ServerName` |
| `ds_Logins` | `SELECT * FROM rpt.FailedLogins WHERE ServerName = @ServerName ORDER BY EventTime DESC` |
| `ds_Growth` | `SELECT Day, SizeGB FROM rpt.GrowthDaily WHERE ServerName=@ServerName AND ObjectName=@Object ORDER BY Day` |
| `ds_Env` | `SELECT DISTINCT Environment FROM cfg.Servers WHERE IsActive=1` *(parameter list)* |

> Parameterised datasets create an `@ServerName` report parameter automatically —
> that's what the drill-through fills in.

## 3. Landing report — `01_EstateHealth.rdl`
A starter scaffold is in this folder (`01_EstateHealth.rdl`) — open it in Report
Builder, point its data source at your `DBADash`, and preview. What it contains /
what to finish:

**Parameter:** `@Environment` (multi-value, default *All*), populated from `ds_Env`,
filtering `ds_Estate` (`WHERE @Environment IS NULL OR Environment IN (@Environment)`).

**KPI textboxes** (top row) — expressions over `ds_Estate`:
- Critical servers: `=CountDistinct(IIf(Fields!OverallStatus.Value="CRIT",Fields!ServerName.Value,Nothing))`
- Warnings, Instances, etc. (same pattern).

**The matrix** — a **Tablix** with fixed columns:
`Server │ Env │ Backup │ Disk │ Jobs │ HA │ Index │ Config │ Perf │ Data`
Row group = `ServerName`. Each domain cell is a textbox whose **Value** is the
field (`=Fields!Backup.Value`) and whose **BackgroundColor** is a RAG `Switch`:

```
=Switch(
   Fields!Backup.Value="CRIT", "#F4C7C7",
   Fields!Backup.Value="WARN", "#F6E2B3",
   Fields!Backup.Value="OK",   "#CDEBD6",
   True,                       "Transparent")
```
Set the **Color** (text) to a matching darker ink and keep the **text = the status
word** (`OK/WARN/CRIT/NA`) so the cell is never colour-alone — accessible and
prints in black-and-white. Use a dark-red/amber/green for the text via the same
`Switch`.

**Drill-through:** on the `ServerName` textbox → *Text Box Properties → Action →
Go to report → `ServerDetail`*, parameter `ServerName = [ServerName]`. (Optionally
give each domain cell its own action to jump straight to that domain's report.)

## 4. Server detail + per-domain reports
`ServerDetail.rdl` takes `@ServerName` and stacks one **tablix per domain**, each
bound to the matching shared dataset above, with the same RAG expression on the
`Status` column. Domains to include (hide the tablix when its dataset is empty via
`Hidden = =Count(Fields!ServerName.Value, "ds_AG")=0`):

- **Backup & Recovery** (`ds_Backup`) — full/log/CHECKDB ages
- **Disk Capacity** (`ds_Disk`) — days-to-full, projected date, "add N GB"
- **AG Sync** (`ds_AG`) — only when the instance hosts a replica
- **Index & Statistics** (`ds_Index`)
- **Configuration** (`ds_Config`)
- **Login Audit** (`ds_Logins`)
- **Database / Table Growth** (`ds_Growth`) — a **Sparkline/Line chart**; add a
  cascading `@Object` parameter from `rpt.GrowthKeys` for the table-level pick.

Redshift instances: swap the Backup/AG/Index tablixes for **Cost Anomaly**
(`rpt.CostAnomaly`), **Load Freshness** (`rpt.DataLag`), and **VACUUM/ANALYZE**
(`rpt.TableHealth`) — same pattern, different dataset.

## 5. Visual polish (SSRS-native)
- **Indicator** report item (traffic-light) in the KPI row instead of a coloured box.
- **Sparkline** inside the matrix for a per-server disk or growth trend.
- Freeze the header row: Tablix → *Advanced Mode* → static member `RepeatOnNewPage
  = True`, `FixedData = True`.
- Enable **document map** on `ServerName` so 50+ servers get a jump-list.

## 6. The morning email (this replaces the inbox)
Two options on the landing report:
- **Standard subscription** — schedule *weekdays 07:30*, render **PDF or MHTML**,
  email the whole team. One estate summary in every inbox.
- **Data-driven subscription** ⭐ — drive recipients from a query so each **app
  owner gets only their servers**:
  ```sql
  SELECT o.Email, o.PrimaryOwner, o.ServerName
  FROM cfg.AppOwners o
  JOIN rpt.EstateHealth e ON e.ServerName = o.ServerName
  WHERE e.OverallStatus <> 'OK';        -- only email when something needs them
  ```
  Map `Email` → *To*, and pass `ServerName`/`@Environment` as the report parameter.
  That's the "no more mass emails — the right person gets the right servers"
  deliverable, native to SSRS.

## 7. Deploy
Report Builder: **Save As** to the Report Server folder (e.g. `/DBADash`).
VS project: set *TargetServerURL* + *TargetReportFolder*, **Deploy**. Set the
shared data source credentials once on the server; every report inherits them.

---

### Why this is the easy sell to a client
No new servers, no new licences, no data leaving the estate — it's a report on a
database, secured by AD, delivered by a scheduler the client's ops team already
runs. The heavy lifting (collection + the `rpt.*` views) is done; SSRS is just the
governed face on top.
