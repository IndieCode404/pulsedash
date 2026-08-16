/*==============================================================================
  DBADash  |  07 - OPTIONAL demo seed
  ----------------------------------------------------------------------------
  Loads fake-but-realistic data so you can open the dashboard and see it work
  BEFORE wiring up real collectors. Safe to skip in production.
  Run cfg.usp_Refresh_DiskForecast after this to populate the forecast tab.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

DELETE FROM mon.AGSyncStatus;  DELETE FROM mon.DataLag;
DELETE FROM mon.DiskUsage;     DELETE FROM cfg.AppOwners;
DELETE FROM cfg.Servers;
GO

INSERT cfg.Servers (ServerName, Platform, Environment, FriendlyName) VALUES
 ('SQLPROD01\AG', 'MSSQL',    'PROD', 'Sales AG Primary'),
 ('SQLPROD02\AG', 'MSSQL',    'PROD', 'Sales AG Secondary'),
 ('SQLPROD03',    'MSSQL',    'PROD', 'Finance Standalone'),
 ('rs-analytics', 'Redshift', 'PROD', 'Analytics Cluster');
GO

-- AG sync snapshot (one healthy db, one lagging db)
INSERT mon.AGSyncStatus (ServerName, AGName, DatabaseName, ReplicaServer, IsPrimary, Role, SyncState, SyncHealth, LogSendQueueKB, RedoQueueKB, LastCommitTime)
VALUES
 ('SQLPROD01\AG','SalesAG','SalesDB','SQLPROD01\AG',1,'PRIMARY','SYNCHRONIZED','HEALTHY',0,0, SYSUTCDATETIME()),
 ('SQLPROD01\AG','SalesAG','SalesDB','SQLPROD02\AG',0,'SECONDARY','SYNCHRONIZED','HEALTHY',12,40, DATEADD(SECOND,-3,SYSUTCDATETIME())),
 ('SQLPROD01\AG','SalesAG','OrdersDB','SQLPROD01\AG',1,'PRIMARY','SYNCHRONIZED','HEALTHY',0,0, SYSUTCDATETIME()),
 ('SQLPROD01\AG','SalesAG','OrdersDB','SQLPROD02\AG',0,'SECONDARY','SYNCHRONIZING','PARTIALLY_HEALTHY',85000,120000, DATEADD(SECOND,-420,SYSUTCDATETIME()));
GO

INSERT mon.DataLag (Platform, ServerName, ObjectName, LagSeconds, Metric, Detail) VALUES
 ('MSSQL','SQLPROD01\AG','AG:SalesDB@SQLPROD02\AG', 3,   'ag_redo_lag','AG=SalesAG; RedoQueueKB=40'),
 ('MSSQL','SQLPROD01\AG','AG:OrdersDB@SQLPROD02\AG', 420,'ag_redo_lag','AG=SalesAG; RedoQueueKB=120000'),
 ('Redshift','rs-analytics','public.fact_sales', 240,  'load_freshness','last load 4 min ago'),
 ('Redshift','rs-analytics','public.dim_customer', 5400,'load_freshness','last load 90 min ago');
GO

-- 30 days of disk history so the forecast has a trend to fit.
-- SQLPROD03 F: climbs steeply (will breach), C: is flat.
DECLARE @d INT = 30;
WHILE @d >= 0
BEGIN
    DECLARE @ts DATETIME2(0) = DATEADD(DAY, -@d, SYSUTCDATETIME());
    INSERT mon.DiskUsage (CollectedAt, Platform, ServerName, VolumeName, TotalBytes, UsedBytes) VALUES
     (@ts,'MSSQL','SQLPROD03','C:\', 268435456000, 120000000000 + (@d*0)),                    -- flat
     (@ts,'MSSQL','SQLPROD03','F:\', 1099511627776, 700000000000 + ((30-@d)*11000000000)),    -- ~11 GB/day
     (@ts,'MSSQL','SQLPROD01\AG','G:\',549755813888, 300000000000 + ((30-@d)*2000000000)),    -- ~2 GB/day
     (@ts,'Redshift','rs-analytics','cluster', 10995116277760, 6000000000000 + ((30-@d)*90000000000)); -- ~90 GB/day
    SET @d -= 1;
END;
GO

INSERT cfg.AppOwners (ServerName, DatabaseName, AppName, Criticality, PrimaryOwner, SecondaryOwner, Team, Email, OnCallPhone, Notes) VALUES
 ('SQLPROD01\AG','SalesDB','Sales Order Portal','Tier1','Priya Nair','Sam Cole','Commerce Platform','commerce-oncall@corp.com','+1-555-0101','PCI in scope'),
 ('SQLPROD03','FinanceDB','GL Consolidation','Tier1','Marco Diaz',NULL,'Finance Systems','fin-sys@corp.com','+1-555-0144',NULL),
 ('rs-analytics','(instance)','Exec Analytics','Tier2','Lena Park','Omar Reed','Data & Insights','data-team@corp.com','+1-555-0199','Nightly ETL 02:00 UTC');
GO

EXEC cfg.usp_Refresh_DiskForecast;
GO

PRINT 'Demo data seeded + forecast refreshed.';
SELECT * FROM rpt.Overview;
GO
