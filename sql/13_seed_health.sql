/*==============================================================================
  DBADash  |  13 - OPTIONAL demo seed for the Health + Activity tabs
  Run AFTER 07 and 11. Re-runs alert evaluation at the end.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO
DELETE FROM mon.BackupStatus; DELETE FROM mon.JobFailure;
DELETE FROM mon.HealthMetric; DELETE FROM mon.QuerySnapshot;
DELETE FROM mon.WaitStats;    DELETE FROM mon.TableHealth;
GO

INSERT mon.BackupStatus (ServerName, DatabaseName, RecoveryModel, StateDesc, LastFullBackup, LastDiffBackup, LastLogBackup, LastGoodCheckDb, PageVerify, IsAutoShrink) VALUES
 ('SQLPROD01\AG','SalesDB','FULL','ONLINE', DATEADD(HOUR,-6,SYSUTCDATETIME()), NULL, DATEADD(MINUTE,-12,SYSUTCDATETIME()), DATEADD(DAY,-3,SYSUTCDATETIME()), 'CHECKSUM', 0),
 ('SQLPROD01\AG','OrdersDB','FULL','ONLINE', DATEADD(HOUR,-30,SYSUTCDATETIME()), NULL, DATEADD(MINUTE,-8,SYSUTCDATETIME()), DATEADD(DAY,-5,SYSUTCDATETIME()), 'CHECKSUM', 0),
 ('SQLPROD03','FinanceDB','FULL','ONLINE', DATEADD(DAY,-9,SYSUTCDATETIME()), DATEADD(DAY,-2,SYSUTCDATETIME()), DATEADD(HOUR,-9,SYSUTCDATETIME()), DATEADD(DAY,-45,SYSUTCDATETIME()), 'CHECKSUM', 0),  -- CRIT: stale full+log, old CHECKDB
 ('SQLPROD03','StagingDB','SIMPLE','ONLINE', DATEADD(DAY,-3,SYSUTCDATETIME()), NULL, NULL, '19000101', 'TORN_PAGE_DETECTION', 1),  -- WARN: no CHECKDB, TORN_PAGE, auto-shrink ON
 ('SQLPROD03','OldAppDB','SIMPLE','OFFLINE', DATEADD(DAY,-40,SYSUTCDATETIME()), NULL, NULL, NULL, 'NONE', 0);       -- CRIT: offline
GO

INSERT mon.JobFailure (ServerName, JobName, StepName, RunAt, Message) VALUES
 ('SQLPROD03','Nightly ETL - Finance','Load GL', DATEADD(HOUR,-7,SYSUTCDATETIME()), 'Violation of PRIMARY KEY constraint PK_GL. The step failed.'),
 ('SQLPROD01\AG','IndexOptimize - USER_DATABASES','IndexOptimize', DATEADD(HOUR,-3,SYSUTCDATETIME()), 'Lock request time out period exceeded. The step failed.');
GO

INSERT mon.HealthMetric (Platform, ServerName, MetricName, MetricValue) VALUES
 ('MSSQL','SQLPROD01\AG','page_life_expectancy', 4200),('MSSQL','SQLPROD01\AG','memory_grants_pending',0),
 ('MSSQL','SQLPROD01\AG','user_sessions',134),('MSSQL','SQLPROD01\AG','blocked_sessions',0),('MSSQL','SQLPROD01\AG','uptime_hours',811),
 ('MSSQL','SQLPROD03','page_life_expectancy', 180),('MSSQL','SQLPROD03','memory_grants_pending',2),
 ('MSSQL','SQLPROD03','user_sessions',67),('MSSQL','SQLPROD03','blocked_sessions',3),('MSSQL','SQLPROD03','uptime_hours',2190),
 ('MSSQL','SQLPROD01\AG','cpu_pct',34),('MSSQL','SQLPROD01\AG','suspect_pages',0),('MSSQL','SQLPROD01\AG','deadlocks_total',12),
 ('MSSQL','SQLPROD03','cpu_pct',91),('MSSQL','SQLPROD03','suspect_pages',2),('MSSQL','SQLPROD03','deadlocks_total',147),
 ('Redshift','rs-analytics','queued_queries',4),('Redshift','rs-analytics','db_connections',88),('Redshift','rs-analytics','load_errors_24h',2);
GO

INSERT mon.QuerySnapshot (Platform, ServerName, SessionID, BlockedBy, Status, WaitType, DurationSec, DatabaseName, LoginName, HostName, ProgramName, QueryText) VALUES
 ('MSSQL','SQLPROD03', 74, 51, 'suspended','LCK_M_X', 312, 'FinanceDB','app_finance','APPSRV02','FinanceAPI','UPDATE dbo.GLEntries SET Posted=1 WHERE BatchID=@b'),
 ('MSSQL','SQLPROD03', 88, 51, 'suspended','LCK_M_S', 285, 'FinanceDB','report_svc','RPTSRV01','SSRS','SELECT SUM(Amount) FROM dbo.GLEntries WHERE ...'),
 ('MSSQL','SQLPROD03', 51,  0, 'running',  NULL,      745, 'FinanceDB','etl_svc','ETL01','DTSExec','BEGIN TRAN; DELETE FROM dbo.GLEntries WHERE Period=...'),
 ('Redshift','rs-analytics', 1201, 0, 'Running', NULL, 1520, 'analytics','etl_user',NULL,NULL,'INSERT INTO fact_sales SELECT * FROM staging_sales s JOIN ...');
GO

INSERT mon.WaitStats (ServerName, WaitType, WaitTimeMs, WaitPct) VALUES
 ('SQLPROD03','LCK_M_X', 9800000, 41.2),('SQLPROD03','PAGEIOLATCH_SH', 6200000, 26.1),
 ('SQLPROD03','CXPACKET', 3100000, 13.0),('SQLPROD03','WRITELOG', 1900000, 8.0),('SQLPROD03','SOS_SCHEDULER_YIELD', 1100000, 4.6),
 ('SQLPROD01\AG','HADR_SYNC_COMMIT', 4200000, 33.5),('SQLPROD01\AG','PAGEIOLATCH_SH', 2800000, 22.3),('SQLPROD01\AG','WRITELOG', 1500000, 12.0);
GO

INSERT mon.TableHealth (ServerName, TableName, UnsortedPct, StatsOffPct, TableRows) VALUES
 ('rs-analytics','public.fact_sales', 62.4, 18.0, 4820000000),   -- CRIT
 ('rs-analytics','public.stg_events', 35.1, 44.9, 91000000),     -- WARN
 ('rs-analytics','public.dim_customer', 12.2, 21.5, 18000000);   -- WARN
GO

EXEC cfg.usp_Evaluate_Alerts;
GO
PRINT 'Health demo seeded + alerts re-evaluated.';
SELECT * FROM rpt.Overview;
GO
