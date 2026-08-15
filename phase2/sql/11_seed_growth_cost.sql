/*==============================================================================
  DBADash  |  11 - OPTIONAL demo seed for Growth + Cost + Alerts
  Run AFTER 07_seed_demo.sql. Populates the Growth chart, triggers a Redshift
  cost anomaly, and raises alerts so every new tab has something to show.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

DELETE FROM mon.ObjectSize;   DELETE FROM mon.RedshiftCost;
DELETE FROM mon.CostAnomaly;  DELETE FROM mon.AlertHistory;
GO

/* ---- 30 days of database / table growth ---- */
DECLARE @d INT = 30;
WHILE @d >= 0
BEGIN
    DECLARE @ts DATETIME2(0) = DATEADD(DAY, -@d, SYSUTCDATETIME());
    INSERT mon.ObjectSize (CollectedAt, Platform, ServerName, ObjectType, ObjectName, SizeBytes) VALUES
     (@ts,'MSSQL','SQLPROD01\AG','database','SalesDB',   80000000000  + ((30-@d)*2100000000)),   -- ~2.1 GB/day
     (@ts,'MSSQL','SQLPROD01\AG','database','OrdersDB',  40000000000  + ((30-@d)*600000000)),     -- ~0.6 GB/day
     (@ts,'MSSQL','SQLPROD03',    'database','FinanceDB', 120000000000 + ((30-@d)*5200000000)),    -- ~5.2 GB/day
     (@ts,'Redshift','rs-analytics','table','public.fact_sales',  900000000000 + ((30-@d)*70000000000)),
     (@ts,'Redshift','rs-analytics','table','public.dim_customer',50000000000  + ((30-@d)*300000000));
    SET @d -= 1;
END;
GO

/* ---- 15 days of Redshift cost drivers, with a spike TODAY ---- */
DECLARE @d INT = 15;
WHILE @d >= 0
BEGIN
    DECLARE @ts DATETIME2(0) = DATEADD(DAY, -@d, SYSUTCDATETIME());
    -- baseline ~0.5 TB/day scanned with mild variation; big spike on day 0
    DECLARE @scan FLOAT = CASE WHEN @d = 0 THEN 3.4 ELSE 0.45 + ((@d % 3) * 0.05) END;
    DECLARE @spec FLOAT = CASE WHEN @d = 0 THEN 0.9 ELSE 0.10 + ((@d % 2) * 0.02) END;
    INSERT mon.RedshiftCost (CollectedAt, ServerName, MetricName, MetricValue, MetricUnit) VALUES
     (@ts,'rs-analytics','bytes_scanned_tb_1d', @scan, 'TB'),
     (@ts,'rs-analytics','spectrum_tb_1d',      @spec, 'TB'),
     (@ts,'rs-analytics','storage_gb',          6000 + ((15-@d)*90), 'GB');
    SET @d -= 1;
END;
GO

/* ---- run the analyzers so Cost + Alerts tabs light up ---- */
EXEC cfg.usp_Detect_CostAnomaly;
EXEC cfg.usp_Evaluate_Alerts;
GO

PRINT 'Growth + cost + alert demo seeded.';
SELECT * FROM rpt.CostAnomaly;
SELECT * FROM rpt.ActiveAlerts;
GO
