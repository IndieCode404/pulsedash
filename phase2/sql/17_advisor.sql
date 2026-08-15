/*==============================================================================
  DBADash  |  17 - Advisor (findings engine)
  ----------------------------------------------------------------------------
  The layer that turns detection into PRESCRIPTION. Collectors stay "dumb" (they
  just snapshot raw evidence); this engine reads those snapshots and emits
  FINDINGS: Problem -> Root cause -> Fix now -> Prevent next time.

  It is deliberately a shared framework, not a one-off: every future advisory
  check (MSSQL blocking, index health, config drift, ...) becomes one more rule
  that appends rows to #f inside cfg.usp_Generate_Findings. The first rule is
  Redshift long lock-waits (> 30 min), classified into four root-cause patterns.

  CRIT findings are surfaced to the existing alert pipeline (Category='Advisor')
  by usp_Evaluate_Alerts v3 below, so they email + dedup like any other alert.

  ORDER DEPENDENCY: Collect-All runs usp_Generate_Findings BEFORE
  usp_Evaluate_Alerts, so findings exist when the alert set is evaluated.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*------------------------------ tables -------------------------------------*/
-- Raw evidence: Redshift sessions waiting on a lock, matched to their blocker.
-- Snapshotted every cycle by Collect-Redshift.ps1 (--==LOCKS==-- block).
IF OBJECT_ID('mon.LockWait') IS NULL
CREATE TABLE mon.LockWait
(
    SnapshotID      BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt     DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName      SYSNAME       NOT NULL,
    WaiterPid       INT           NULL,
    WaiterUser      NVARCHAR(128) NULL,
    Relation        NVARCHAR(256) NULL,     -- table the waiter is blocked on
    WaitMinutes     INT           NULL,     -- approx age of the blocked txn
    WaiterQuery     NVARCHAR(500) NULL,
    BlockerPid      INT           NULL,
    BlockerUser     NVARCHAR(128) NULL,
    BlockerLockMode NVARCHAR(60)  NULL,
    BlockerIdleInTxn TINYINT      NULL,     -- 1 = holds lock with no running query (loaded from ODBC as int, not bit)
    BlockerQuery    NVARCHAR(500) NULL,
    ConflictCount24h INT          NULL      -- serialization aborts on this table, 24h
);
GO

-- The advisor's output: one row per active problem, auto-resolved when it clears.
IF OBJECT_ID('mon.Finding') IS NULL
CREATE TABLE mon.Finding
(
    FindingID      BIGINT IDENTITY(1,1) PRIMARY KEY,
    FindingKey     NVARCHAR(300) NOT NULL,          -- stable dedup id for the condition
    Platform       VARCHAR(20)   NULL,
    Category       VARCHAR(30)   NOT NULL,          -- Blocking | Index | Config | ...
    Severity       VARCHAR(10)   NOT NULL,          -- INFO | WARN | CRIT
    ServerName     SYSNAME       NULL,
    Title          NVARCHAR(200) NOT NULL,
    Symptom        NVARCHAR(600) NULL,              -- what we observed
    RootCause      NVARCHAR(600) NULL,              -- why it is happening
    Recommendation NVARCHAR(800) NULL,              -- fix now
    Prevention     NVARCHAR(800) NULL,              -- avoid next time
    Evidence       NVARCHAR(1000) NULL,             -- pids / timestamps / sql
    FirstSeen      DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    LastSeen       DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Resolved       BIT           NOT NULL DEFAULT 0,
    ResolvedAt     DATETIME2(0)  NULL
);
GO
-- One ACTIVE finding per key (resolved rows are exempt, so history accrues).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_Finding_Active' AND object_id=OBJECT_ID('mon.Finding'))
CREATE UNIQUE INDEX UX_Finding_Active ON mon.Finding (FindingKey) WHERE Resolved = 0;
GO

/*---------------------------------------------------------------------------
  cfg.usp_Generate_Findings  -  the rules engine.
  Reads the latest snapshots, classifies each problem, and upserts findings.
  @BlockMinutes: lock-wait age (minutes) at which a Redshift block is a finding.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_Generate_Findings
    @BlockMinutes INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #f (
        FindingKey NVARCHAR(300), Platform VARCHAR(20), Category VARCHAR(30),
        Severity VARCHAR(10), ServerName SYSNAME NULL, Title NVARCHAR(200),
        Symptom NVARCHAR(600), RootCause NVARCHAR(600),
        Recommendation NVARCHAR(800), Prevention NVARCHAR(800), Evidence NVARCHAR(1000));

    /*=== RULE 1: Redshift long lock-wait (> @BlockMinutes), classified ======
      Four root-cause patterns, each with its own fix + prevention text:
        IDLE_TXN  - blocker holds the lock but runs nothing (open BEGIN)
        DDL       - a DDL statement is queued behind a long read/write
        CONFLICT  - serialization aborts: concurrent overlapping writers
        VACUUM    - a VACUUM/maintenance op holds the lock
        GENERIC   - a plain long-running transaction                          */
    ;WITH latest AS (
        SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
        FROM mon.LockWait
    ),
    cls AS (
        SELECT *,
            Pattern = CASE
                WHEN BlockerIdleInTxn = 1 THEN 'IDLE_TXN'
                WHEN WaiterQuery LIKE 'ALTER%'  OR WaiterQuery LIKE 'DROP%'
                  OR WaiterQuery LIKE 'TRUNCATE%' OR WaiterQuery LIKE 'CREATE%' THEN 'DDL'
                WHEN ISNULL(ConflictCount24h,0) > 0 THEN 'CONFLICT'
                WHEN BlockerQuery LIKE '%VACUUM%' OR WaiterQuery LIKE 'VACUUM%' THEN 'VACUUM'
                ELSE 'GENERIC' END
        FROM latest
        WHERE rn = 1 AND ISNULL(WaitMinutes,0) >= @BlockMinutes
    )
    INSERT #f
    SELECT
        FindingKey = CONCAT('RSBlock|', ServerName, '|', WaiterPid, '|', Relation),
        Platform   = 'Redshift', Category = 'Blocking', Severity = 'CRIT',
        ServerName,
        Title = CONCAT('Lock wait ', WaitMinutes, ' min on ', Relation,
                       ' (PID ', WaiterPid, ' blocked by PID ', BlockerPid, ')'),
        Symptom = CONCAT('PID ', WaiterPid, ' (', ISNULL(WaiterUser,'?'),
                         ') has waited ', WaitMinutes, ' min for a lock on ', Relation,
                         ', held by PID ', BlockerPid, ' (', ISNULL(BlockerUser,'?'), ').'),
        RootCause = CASE Pattern
            WHEN 'IDLE_TXN' THEN CONCAT('Blocker PID ', BlockerPid,
                ' holds the lock but has no running query - it is idle inside an open '
                + 'transaction. A session or app issued BEGIN and never COMMIT/ROLLBACK.')
            WHEN 'DDL'      THEN 'A DDL statement (ALTER/DROP/TRUNCATE/CREATE) is queued behind a '
                + 'longer read/write on the same table; DDL needs an exclusive lock.'
            WHEN 'CONFLICT' THEN CONCAT(ConflictCount24h, ' serialization-isolation aborts on this '
                + 'table in the last 24h - concurrent transactions are writing overlapping rows '
                + 'and serializing on each other.')
            WHEN 'VACUUM'   THEN 'A VACUUM / maintenance operation holds a lock that conflicts with '
                + 'writers on the table.'
            ELSE 'A long-running transaction is holding a conflicting lock; the waiter cannot '
                + 'proceed until it commits.' END,
        Recommendation = CASE Pattern
            WHEN 'IDLE_TXN' THEN CONCAT('Confirm the owner of PID ', BlockerPid,
                ' is safe to release, then: SELECT pg_terminate_backend(', BlockerPid, ');')
            WHEN 'DDL'      THEN CONCAT('Let the current statement finish, or reschedule the DDL. '
                + 'If the DDL is urgent, cancel the blocker: SELECT pg_terminate_backend(', BlockerPid, ');')
            WHEN 'CONFLICT' THEN 'Retry the aborted transactions, and serialize the competing writers '
                + '(one writer, or load a staging table then a single MERGE).'
            WHEN 'VACUUM'   THEN 'Wait for VACUUM to complete; avoid killing it mid-run. If it must '
                + 'yield, cancel it and reschedule off-peak.'
            ELSE CONCAT('Identify the blocker and, once confirmed safe, cancel it: '
                + 'SELECT pg_terminate_backend(', BlockerPid, ');') END,
        Prevention = CASE Pattern
            WHEN 'IDLE_TXN' THEN 'Set an idle-session / statement timeout; make the app COMMIT or '
                + 'ROLLBACK deterministically; do not leave BEGIN open in ad-hoc SQL tools; alert '
                + 'on idle-in-transaction sessions.'
            WHEN 'DDL'      THEN 'Run DDL in a maintenance window, keep read/write transactions short, '
                + 'and use late-binding views to swap tables without holding long locks.'
            WHEN 'CONFLICT' THEN 'Stagger ETL so writers to the same table do not overlap; funnel '
                + 'writes through a staging table + single MERGE; keep transactions small.'
            WHEN 'VACUUM'   THEN 'Schedule VACUUM off-peak, enable auto-vacuum, and vacuum narrower '
                + 'table ranges to shorten lock windows.'
            ELSE 'Keep transactions short and commit promptly; monitor for transactions open longer '
                + 'than your SLA.' END,
        Evidence = CONCAT('waiter_pid=', WaiterPid, ' blocker_pid=', BlockerPid,
                          ' lock_mode=', ISNULL(BlockerLockMode,'?'), ' wait_min=', WaitMinutes,
                          ' idle_in_txn=', BlockerIdleInTxn, ' conflicts_24h=', ISNULL(ConflictCount24h,0),
                          CASE WHEN BlockerQuery IS NOT NULL
                               THEN CONCAT(' blocker_sql="', LEFT(BlockerQuery,120), '"') ELSE '' END)
    FROM cls;

    /* future rules append more rows to #f here (MSSQL blocking, index, config...) */

    /*--- upsert into mon.Finding, preserving FirstSeen on existing conditions ---*/
    MERGE mon.Finding AS t
    USING #f AS s ON t.FindingKey = s.FindingKey AND t.Resolved = 0
    WHEN MATCHED THEN UPDATE SET
        t.Severity = s.Severity, t.Title = s.Title, t.Symptom = s.Symptom,
        t.RootCause = s.RootCause, t.Recommendation = s.Recommendation,
        t.Prevention = s.Prevention, t.Evidence = s.Evidence, t.LastSeen = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (FindingKey, Platform, Category, Severity, ServerName, Title, Symptom,
         RootCause, Recommendation, Prevention, Evidence)
        VALUES (s.FindingKey, s.Platform, s.Category, s.Severity, s.ServerName, s.Title, s.Symptom,
                s.RootCause, s.Recommendation, s.Prevention, s.Evidence);

    /*--- auto-resolve findings in the rule domains we just re-evaluated ---
      (only Redshift/Blocking today; widen the WHERE as new rules are added). */
    UPDATE t SET Resolved = 1, ResolvedAt = SYSUTCDATETIME()
    FROM mon.Finding t
    WHERE t.Resolved = 0
      AND t.Platform = 'Redshift' AND t.Category = 'Blocking'
      AND NOT EXISTS (SELECT 1 FROM #f f WHERE f.FindingKey = t.FindingKey);

    SELECT OpenFindings = (SELECT COUNT(*) FROM mon.Finding WHERE Resolved = 0);
END;
GO

/*------------------------------ view ---------------------------------------*/
CREATE OR ALTER VIEW rpt.Findings
AS
SELECT FindingID, FindingKey, Platform, Category, Severity, ServerName,
       Title, Symptom, RootCause, Recommendation, Prevention, Evidence,
       FirstSeen, LastSeen,
       AgeMinutes = DATEDIFF(MINUTE, FirstSeen, SYSUTCDATETIME())
FROM mon.Finding
WHERE Resolved = 0;
GO

/*------------- rpt.Overview v3 (adds the open-findings KPI) ----------------*/
CREATE OR ALTER VIEW rpt.Overview
AS
SELECT
    Servers            = (SELECT COUNT(*) FROM cfg.Servers WHERE IsActive = 1),
    MSSQLServers       = (SELECT COUNT(*) FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'MSSQL'),
    RedshiftClusters   = (SELECT COUNT(*) FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'Redshift'),
    AGDatabases        = (SELECT COUNT(*) FROM rpt.AGSyncStatus),
    AGUnhealthy        = (SELECT COUNT(*) FROM rpt.AGSyncStatus WHERE Status <> 'OK'),
    LagObjectsCrit     = (SELECT COUNT(*) FROM rpt.DataLag      WHERE Status = 'CRIT'),
    DisksCrit          = (SELECT COUNT(*) FROM rpt.DiskForecast WHERE Severity = 'CRIT'),
    DisksWarn          = (SELECT COUNT(*) FROM rpt.DiskForecast WHERE Severity = 'WARN'),
    BackupsAtRisk      = (SELECT COUNT(*) FROM rpt.BackupHealth WHERE Status <> 'OK'),
    JobFailures24h     = (SELECT COUNT(*) FROM rpt.JobFailures  WHERE RunAt >= DATEADD(HOUR,-24,SYSUTCDATETIME())),
    BlockedSessions    = (SELECT ISNULL(SUM(MetricValue),0) FROM rpt.InstanceVitals WHERE MetricName='blocked_sessions'),
    OpenFindings       = (SELECT COUNT(*) FROM mon.Finding WHERE Resolved = 0),
    AppsWithoutOwner   = (SELECT COUNT(*) FROM cfg.Servers s
                          WHERE s.IsActive = 1
                            AND NOT EXISTS (SELECT 1 FROM cfg.AppOwners a WHERE a.ServerName = s.ServerName)),
    LastCollection     = (SELECT MAX(RunAt) FROM cfg.CollectionLog WHERE Status = 'OK');
GO

/*------- cfg.usp_Evaluate_Alerts v3 (supersedes sql\12): + Advisor ---------
  Identical to v2 but also pulls CRIT Advisor findings into the alert set, so
  a >30 min block emails through the existing pipeline and dedups/auto-resolves
  with all the other categories.                                             */
CREATE OR ALTER PROCEDURE cfg.usp_Evaluate_Alerts
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #cur (AlertKey NVARCHAR(300), Category VARCHAR(20), Severity VARCHAR(10),
                       ServerName SYSNAME NULL, Message NVARCHAR(600));

    INSERT #cur
    SELECT CONCAT('Disk|',ServerName,'|',VolumeName), 'Disk', Severity, ServerName,
           CONCAT(ServerName,' ',VolumeName,' at ',UsedPct,'% - full in ',
                  ISNULL(CAST(DaysToFull AS VARCHAR(10)),'?'),' days (add +',
                  ISNULL(CAST(RecommendedAddGB AS VARCHAR(10)),'?'),' GB)')
    FROM rpt.DiskForecast WHERE Severity IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('AG|',AGName,'|',DatabaseName,'|',ReplicaServer), 'AG', Status, ReplicaServer,
           CONCAT('AG ',AGName,' / ',DatabaseName,' on ',ReplicaServer,' is ',SyncState,' / ',SyncHealth)
    FROM rpt.AGSyncStatus WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('Lag|',ServerName,'|',ObjectName), 'Lag', Status, ServerName,
           CONCAT(Platform,' ',ObjectName,' lag = ',ISNULL(CAST(LagSeconds AS VARCHAR(20)),'?'),'s')
    FROM rpt.DataLag WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('Cost|',ServerName,'|',MetricName,'|',ObservedDay), 'Cost', Severity, ServerName,
           CONCAT('Cost spike: ',MetricName,' = ',Value,' (',PctAboveBaseline,'% over baseline)')
    FROM rpt.CostAnomaly WHERE ObservedDay >= CAST(SYSUTCDATETIME() AS DATE);

    INSERT #cur
    SELECT CONCAT('Backup|',ServerName,'|',DatabaseName), 'Backup', Status, ServerName,
           CONCAT(DatabaseName,' [',StateDesc,'/',RecoveryModel,'] last full ',
                  ISNULL(CONVERT(VARCHAR(16),LastFullBackup,120),'NEVER'),
                  ', last log ', ISNULL(CONVERT(VARCHAR(16),LastLogBackup,120),'n/a'),
                  ', last CHECKDB ', ISNULL(CONVERT(VARCHAR(10),LastGoodCheckDb,120),'NEVER'))
    FROM rpt.BackupHealth WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('Job|',ServerName,'|',JobName,'|',CONVERT(VARCHAR(16),RunAt,120)), 'Job', 'WARN', ServerName,
           CONCAT('Agent job failed: ',JobName,' (',ISNULL(StepName,'?'),') at ',CONVERT(VARCHAR(16),RunAt,120))
    FROM rpt.JobFailures WHERE RunAt >= DATEADD(HOUR, -24, SYSUTCDATETIME());

    INSERT #cur
    SELECT CONCAT('Vitals|',ServerName,'|',MetricName), 'Vitals', Status, ServerName,
           CONCAT(ServerName,' ',MetricName,' = ',CAST(MetricValue AS VARCHAR(20)))
    FROM rpt.InstanceVitals WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('TableHealth|',ServerName,'|',TableName), 'TableHealth', Status, ServerName,
           CONCAT(TableName,' unsorted=',UnsortedPct,'% stats_off=',StatsOffPct,'% - run VACUUM/ANALYZE')
    FROM rpt.TableHealth WHERE Status = 'CRIT';

    -- Advisor: CRIT findings (e.g. Redshift blocking > 30 min) join the alert set.
    INSERT #cur
    SELECT CONCAT('Advisor|',FindingKey), 'Advisor', Severity, ServerName,
           LEFT(CONCAT(Title,' - ',Recommendation), 600)
    FROM rpt.Findings WHERE Severity = 'CRIT';

    MERGE mon.AlertHistory AS t
    USING #cur AS s ON t.AlertKey = s.AlertKey AND t.Resolved = 0
    WHEN MATCHED THEN UPDATE SET
        t.Severity = s.Severity, t.Message = s.Message, t.LastSeen = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (AlertKey, Category, Severity, ServerName, Message)
        VALUES (s.AlertKey, s.Category, s.Severity, s.ServerName, s.Message);

    UPDATE t SET Resolved = 1, ResolvedAt = SYSUTCDATETIME()
    FROM mon.AlertHistory t
    WHERE t.Resolved = 0
      AND NOT EXISTS (SELECT 1 FROM #cur c WHERE c.AlertKey = t.AlertKey);

    SELECT ActiveAlerts = (SELECT COUNT(*) FROM mon.AlertHistory WHERE Resolved = 0);
END;
GO

/*-------- purge v4 (supersedes sql\15): also cover LockWait + Finding -------*/
CREATE OR ALTER PROCEDURE cfg.usp_Purge_History
    @RetentionDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cut DATETIME2(0) = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());
    DELETE FROM mon.AGSyncStatus  WHERE CollectedAt < @cut;
    DELETE FROM mon.DataLag       WHERE CollectedAt < @cut;
    DELETE FROM mon.DiskUsage     WHERE CollectedAt < @cut;
    DELETE FROM mon.ObjectSize    WHERE CollectedAt < @cut;
    DELETE FROM mon.RedshiftCost  WHERE CollectedAt < @cut;
    DELETE FROM mon.BackupStatus  WHERE CollectedAt < @cut;
    DELETE FROM mon.JobFailure    WHERE CollectedAt < @cut;
    DELETE FROM mon.HealthMetric  WHERE CollectedAt < @cut;
    DELETE FROM mon.QuerySnapshot WHERE CollectedAt < @cut;
    DELETE FROM mon.WaitStats     WHERE CollectedAt < @cut;
    DELETE FROM mon.TableHealth   WHERE CollectedAt < @cut;
    DELETE FROM mon.TopQueries    WHERE CollectedAt < @cut;
    DELETE FROM mon.FailedLogin   WHERE CollectedAt < @cut;
    DELETE FROM mon.LoginActivity WHERE CollectedAt < @cut;
    DELETE FROM mon.SpectrumScan  WHERE CollectedAt < @cut;
    DELETE FROM mon.LockWait      WHERE CollectedAt < @cut;
    DELETE FROM mon.Finding       WHERE Resolved = 1 AND ResolvedAt < @cut;  -- keep open findings
    -- mon.TableScan is intentionally NOT purged by retention (stale-table history);
    -- dedupe it to one row per table per day instead.
    ;WITH d AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, TableName, CAST(LastScanned AS DATE) ORDER BY SnapshotID DESC)
                FROM mon.TableScan)
    DELETE FROM d WHERE rn > 1;
    DELETE FROM cfg.CollectionLog WHERE RunAt < @cut;
END;
GO

PRINT 'Advisor / findings-engine objects created (17).';
GO
