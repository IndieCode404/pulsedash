/*==============================================================================
  DBADash  |  09 - Redshift cost-driver tracking + anomaly detection
  ----------------------------------------------------------------------------
  Redshift bills you for USAGE, not rows, so "cost anomaly" = an unusual spike
  in a cost driver. We capture the drivers you can see from inside the cluster:
      - Spectrum TB scanned      (billed at ~$5/TB)      -> spectrum_tb_1d
      - Serverless RPU-hours     (billed per RPU-hour)   -> serverless_rpu_hours_1d
      - Total bytes scanned      (RA3 scaling proxy)     -> bytes_scanned_tb_1d
      - Storage used             (managed storage)       -> storage_gb
  (Edit redshift\redshift_metrics.sql to match your edition.)

  Detection = rolling z-score: compare today's value to the trailing @Window-day
  baseline (mean + stddev). This complements, not replaces, AWS Cost Anomaly
  Detection / Cost Explorer - see docs\COST_ANOMALY.md for the AWS-side pointers.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('mon.RedshiftCost') IS NULL
CREATE TABLE mon.RedshiftCost
(
    SnapshotID   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt  DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName   SYSNAME      NOT NULL,       -- cluster id
    MetricName   VARCHAR(60)  NOT NULL,
    MetricValue  FLOAT        NOT NULL,
    MetricUnit   VARCHAR(20)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_RedshiftCost_Trend' AND object_id=OBJECT_ID('mon.RedshiftCost'))
CREATE INDEX IX_RedshiftCost_Trend ON mon.RedshiftCost (ServerName, MetricName, CollectedAt);
GO

IF OBJECT_ID('mon.CostAnomaly') IS NULL
CREATE TABLE mon.CostAnomaly
(
    AnomalyID        BIGINT IDENTITY(1,1) PRIMARY KEY,
    ServerName       SYSNAME      NOT NULL,
    MetricName       VARCHAR(60)  NOT NULL,
    MetricUnit       VARCHAR(20)  NULL,
    ObservedDay      DATE         NOT NULL,
    Value            FLOAT        NOT NULL,
    Baseline         FLOAT        NULL,
    StdDev           FLOAT        NULL,
    ZScore           DECIMAL(10,2) NULL,
    PctAboveBaseline DECIMAL(10,1) NULL,
    Severity         VARCHAR(10)  NOT NULL,   -- WARN | CRIT
    DetectedAt       DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_CostAnomaly UNIQUE (ServerName, MetricName, ObservedDay)
);
GO

/*---------------------------------------------------------------------------
  cfg.usp_Detect_CostAnomaly
  Flags today's cost-driver value if it spikes vs. the trailing baseline.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_Detect_CostAnomaly
    @Window   INT   = 14,     -- baseline lookback (days)
    @WarnZ    FLOAT = 2.5,    -- z-score thresholds
    @CritZ    FLOAT = 4.0,
    @WarnPct  FLOAT = 50,     -- % above baseline thresholds (for low-variance metrics)
    @CritPct  FLOAT = 100
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH daily AS
    (
        SELECT ServerName, MetricName, MetricUnit,
               Day = CAST(CollectedAt AS DATE),
               Val = MAX(MetricValue)        -- daily peak of the driver
        FROM mon.RedshiftCost
        WHERE CollectedAt >= DATEADD(DAY, -(@Window + 1), SYSUTCDATETIME())
        GROUP BY ServerName, MetricName, MetricUnit, CAST(CollectedAt AS DATE)
    ),
    ranked AS
    (
        SELECT *, r = ROW_NUMBER() OVER (PARTITION BY ServerName, MetricName ORDER BY Day DESC)
        FROM daily
    ),
    cur AS (SELECT * FROM ranked WHERE r = 1),
    base AS
    (
        SELECT d.ServerName, d.MetricName,
               mean = AVG(d.Val), sd = STDEV(d.Val), n = COUNT(*)
        FROM daily d
        JOIN cur c ON c.ServerName = d.ServerName AND c.MetricName = d.MetricName
        WHERE d.Day < c.Day
        GROUP BY d.ServerName, d.MetricName
    )
    INSERT mon.CostAnomaly
        (ServerName, MetricName, MetricUnit, ObservedDay, Value, Baseline, StdDev, ZScore, PctAboveBaseline, Severity)
    SELECT
        c.ServerName, c.MetricName, c.MetricUnit, c.Day, c.Val,
        b.mean, b.sd,
        ZScore   = CASE WHEN b.sd > 0 THEN CAST((c.Val - b.mean) / b.sd AS DECIMAL(10,2)) END,
        PctAbove = CASE WHEN b.mean > 0 THEN CAST(100.0 * (c.Val - b.mean) / b.mean AS DECIMAL(10,1)) END,
        Severity = CASE
                     WHEN (b.sd > 0 AND (c.Val - b.mean) / b.sd >= @CritZ)
                       OR (b.mean > 0 AND 100.0 * (c.Val - b.mean) / b.mean >= @CritPct) THEN 'CRIT'
                     ELSE 'WARN' END
    FROM cur c
    JOIN base b ON b.ServerName = c.ServerName AND b.MetricName = c.MetricName
    WHERE b.n >= 3                                 -- need some history
      AND c.Val > b.mean                           -- only positive spikes cost money
      AND ( (b.sd > 0 AND (c.Val - b.mean) / b.sd >= @WarnZ)
         OR (b.mean > 0 AND 100.0 * (c.Val - b.mean) / b.mean >= @WarnPct) )
      AND NOT EXISTS (SELECT 1 FROM mon.CostAnomaly a
                      WHERE a.ServerName = c.ServerName AND a.MetricName = c.MetricName
                        AND a.ObservedDay = c.Day);

    INSERT cfg.CollectionLog (Collector, Status, RowsLoaded, Message)
    VALUES ('CostAnomaly', 'OK', @@ROWCOUNT, 'Cost anomaly scan complete');
END;
GO

/*---------------------------------------------------------------------------
  rpt.CostAnomaly  -  recent anomalies for the dashboard "Cost" tab.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.CostAnomaly
AS
SELECT TOP (500)
    ServerName, MetricName, MetricUnit, ObservedDay,
    Value    = CAST(Value    AS DECIMAL(18,3)),
    Baseline = CAST(Baseline AS DECIMAL(18,3)),
    ZScore, PctAboveBaseline, Severity, DetectedAt
FROM mon.CostAnomaly
WHERE ObservedDay >= DATEADD(DAY, -30, CAST(SYSUTCDATETIME() AS DATE))
ORDER BY DetectedAt DESC, PctAboveBaseline DESC;
GO

/*---------------------------------------------------------------------------
  rpt.CostTrend  -  daily cost-driver values (for optional charting).
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.CostTrend
AS
SELECT ServerName, MetricName, MetricUnit,
       Day = CAST(CollectedAt AS DATE),
       Value = CAST(MAX(MetricValue) AS DECIMAL(18,3))
FROM mon.RedshiftCost
GROUP BY ServerName, MetricName, MetricUnit, CAST(CollectedAt AS DATE);
GO

PRINT 'Cost tracking + anomaly detection created.';
GO
