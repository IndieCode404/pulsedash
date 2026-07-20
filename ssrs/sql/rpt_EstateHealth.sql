/*==============================================================================
  DBADash  |  SSRS - rpt.EstateHealth  (the landing matrix source)
  ----------------------------------------------------------------------------
  ONE ROW PER SERVER, one column per domain, each holding a worst-of RAG status
  (OK / WARN / CRIT / NA). This "wide" shape is what an SSRS tablix wants: fixed
  columns, one textbox per domain, RAG via a BackgroundColor expression - far
  simpler and more robust to author than a dynamic matrix column-group.

  It reuses the existing DBADash rpt.* views, so there is no new collection - the
  SSRS report is a second face on the same data the HTML dashboard reads.

  Deploy AFTER the main DBADash schema (needs rpt.BackupHealth, rpt.DiskForecast,
  rpt.AGSyncStatus, rpt.JobFailures, rpt.IndexHealth, rpt.ConfigAudit,
  rpt.InstanceVitals, rpt.DataLag, rpt.TableHealth).
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW rpt.EstateHealth
AS
WITH est AS
(
    SELECT
        s.ServerName,
        s.Environment,
        s.Platform,
        s.FriendlyName,
        -- worst backup RPO / CHECKDB state for the instance
        [Backup]  = ISNULL((SELECT CASE MIN(CASE b.Status WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
                                     WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END
                            FROM rpt.BackupHealth b WHERE b.ServerName = s.ServerName), 'NA'),
        -- volume fill forecast
        [Disk]    = ISNULL((SELECT CASE MIN(CASE d.Severity WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
                                     WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END
                            FROM rpt.DiskForecast d WHERE d.ServerName = s.ServerName), 'NA'),
        -- any agent-job failure in the last 24h
        [Jobs]    = CASE WHEN s.Platform <> 'MSSQL' THEN 'NA'
                         WHEN EXISTS (SELECT 1 FROM rpt.JobFailures j
                                      WHERE j.ServerName = s.ServerName
                                        AND j.RunAt >= DATEADD(HOUR, -24, SYSUTCDATETIME())) THEN 'WARN'
                         ELSE 'OK' END,
        -- AG sync (NA if this instance hosts no AG replica)
        [HA]      = ISNULL((SELECT CASE MIN(CASE a.Status WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
                                     WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END
                            FROM rpt.AGSyncStatus a WHERE a.ReplicaServer = s.ServerName), 'NA'),
        -- missing / fragmented indexes
        [Index]   = ISNULL((SELECT CASE MIN(CASE i.Status WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
                                     WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END
                            FROM rpt.IndexHealth i WHERE i.ServerName = s.ServerName), 'NA'),
        -- configuration drift
        [Config]  = ISNULL((SELECT CASE MIN(CASE c.Status WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
                                     WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END
                            FROM rpt.ConfigAudit c WHERE c.ServerName = s.ServerName), 'NA'),
        -- instance vitals (PLE / blocking / tempdb / VLF ...)
        [Perf]    = ISNULL((SELECT CASE MIN(CASE v.Status WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
                                     WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END
                            FROM rpt.InstanceVitals v WHERE v.ServerName = s.ServerName), 'NA'),
        -- data currency: AG/ETL lag + Redshift table maintenance
        [Data]    = ISNULL((SELECT CASE MIN(rk) WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END FROM (
                                SELECT rk = CASE l.Status WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END
                                FROM rpt.DataLag l WHERE l.ServerName = s.ServerName
                                UNION ALL
                                SELECT CASE t.Status WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END
                                FROM rpt.TableHealth t WHERE t.ServerName = s.ServerName
                            ) z), 'NA')
    FROM cfg.Servers s
    WHERE s.IsActive = 1
)
SELECT
    ServerName, Environment, Platform, FriendlyName,
    [Backup], [Disk], [Jobs], [HA], [Index], [Config], [Perf], [Data],
    -- overall = worst of the domains, for the KPI header + default sort
    OverallRank = (SELECT MIN(r) FROM (VALUES
        (CASE [Backup] WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Disk]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Jobs]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [HA]     WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Index]  WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Config] WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Perf]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Data]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
      ) v(r)),
    OverallStatus = CASE (SELECT MIN(r) FROM (VALUES
        (CASE [Backup] WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Disk]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Jobs]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [HA]     WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Index]  WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Config] WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Perf]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END),
        (CASE [Data]   WHEN 'CRIT' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END)
      ) v(r)) WHEN 0 THEN 'CRIT' WHEN 1 THEN 'WARN' ELSE 'OK' END
FROM est;
GO

PRINT 'rpt.EstateHealth created - point the SSRS landing tablix at this view.';
GO
