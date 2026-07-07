/*==============================================================================
  DBADash  |  08 - Database / table growth tracking (MSSQL + Redshift)
  ----------------------------------------------------------------------------
  mon.ObjectSize is a unified size time-series:
     MSSQL    -> one row per DATABASE  (sum of file sizes)
     Redshift -> one row per TABLE     (svv_table_info)
  The dashboard "Growth" tab draws an SVG line chart straight from rpt.GrowthDaily.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('mon.ObjectSize') IS NULL
CREATE TABLE mon.ObjectSize
(
    SnapshotID   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Platform     VARCHAR(20)   NOT NULL,       -- MSSQL | Redshift
    ServerName   SYSNAME       NOT NULL,
    ObjectType   VARCHAR(20)   NOT NULL,       -- database | table
    ObjectName   NVARCHAR(256) NOT NULL,
    SizeBytes    BIGINT        NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_ObjectSize_Trend' AND object_id=OBJECT_ID('mon.ObjectSize'))
CREATE INDEX IX_ObjectSize_Trend ON mon.ObjectSize (Platform, ServerName, ObjectName, CollectedAt);
GO

/*---------------------------------------------------------------------------
  rpt.GrowthDaily  -  one point per object per day (last snapshot of the day).
  This is the series the chart plots.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.GrowthDaily
AS
WITH d AS
(
    SELECT Platform, ServerName, ObjectType, ObjectName,
           Day = CAST(CollectedAt AS DATE), SizeBytes,
           rn = ROW_NUMBER() OVER (
                  PARTITION BY Platform, ServerName, ObjectName, CAST(CollectedAt AS DATE)
                  ORDER BY CollectedAt DESC)
    FROM mon.ObjectSize
)
SELECT Platform, ServerName, ObjectType, ObjectName, Day,
       SizeGB = CAST(SizeBytes / 1073741824.0 AS DECIMAL(18,3))
FROM d
WHERE rn = 1;
GO

/*---------------------------------------------------------------------------
  rpt.GrowthKeys  -  one row per tracked object: current size + growth rate.
  Powers the object picker AND the "top movers" grid.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.GrowthKeys
AS
WITH s AS
(
    SELECT Platform, ServerName, ObjectType, ObjectName, SizeBytes, CollectedAt,
           rnNew = ROW_NUMBER() OVER (PARTITION BY Platform,ServerName,ObjectName ORDER BY CollectedAt DESC),
           rnOld = ROW_NUMBER() OVER (PARTITION BY Platform,ServerName,ObjectName ORDER BY CollectedAt ASC)
    FROM mon.ObjectSize
),
n AS (SELECT * FROM s WHERE rnNew = 1),
o AS (SELECT * FROM s WHERE rnOld = 1)
SELECT
    n.Platform, n.ServerName, n.ObjectType, n.ObjectName,
    CurrentGB = CAST(n.SizeBytes / 1073741824.0 AS DECIMAL(18,2)),
    DeltaGB   = CAST((n.SizeBytes - o.SizeBytes) / 1073741824.0 AS DECIMAL(18,2)),
    WindowDays = DATEDIFF(DAY, o.CollectedAt, n.CollectedAt),
    GrowthGBPerDay = CAST(
        CASE WHEN DATEDIFF(DAY, o.CollectedAt, n.CollectedAt) > 0
             THEN (n.SizeBytes - o.SizeBytes) / 1073741824.0
                  / DATEDIFF(DAY, o.CollectedAt, n.CollectedAt)
             ELSE 0 END AS DECIMAL(18,3))
FROM n
JOIN o ON o.Platform = n.Platform AND o.ServerName = n.ServerName AND o.ObjectName = n.ObjectName;
GO

PRINT 'Growth tracking objects created.';
GO
