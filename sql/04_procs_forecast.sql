/*==============================================================================
  DBADash  |  04 - Forecast + retention procedures (run in DBADash)
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*---------------------------------------------------------------------------
  cfg.usp_Refresh_DiskForecast
  ----------------------------------------------------------------------------
  Fits a least-squares trend line (UsedBytes vs. time) over the last
  @LookbackDays of history for each volume, then projects "days until full".

    slope (bytes/day) = (n*Σxy - Σx*Σy) / (n*Σx² - (Σx)²)     where x = days

  Sizing: RecommendedAddGB buys ~@HeadroomDays of headroom at the current
  growth rate. Severity thresholds mirror the classic Ozar/Dave playbook.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_Refresh_DiskForecast
    @LookbackDays INT = 30,
    @HeadroomDays INT = 180,     -- how much runway a new disk should buy
    @WarnDays     INT = 45,      -- amber if full within this many days
    @CritDays     INT = 14       -- red   if full within this many days
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH src AS
    (
        SELECT Platform, ServerName, VolumeName,
               -- days since 2000-01-01 as float (datetime2 cannot be CAST to float)
               x = DATEDIFF_BIG(SECOND, '20000101', CollectedAt) / 86400.0,
               y = CAST(UsedBytes AS FLOAT),
               TotalBytes, UsedBytes, UsedPct, CollectedAt
        FROM mon.DiskUsage
        WHERE CollectedAt >= DATEADD(DAY, -@LookbackDays, SYSUTCDATETIME())
    ),
    latest AS      -- most recent snapshot per volume = "current" numbers
    (
        SELECT Platform, ServerName, VolumeName, TotalBytes, UsedBytes, UsedPct,
               rn = ROW_NUMBER() OVER (PARTITION BY Platform, ServerName, VolumeName
                                       ORDER BY CollectedAt DESC)
        FROM src
    ),
    reg AS         -- regression aggregates per volume
    (
        SELECT Platform, ServerName, VolumeName,
               n   = COUNT_BIG(*),
               sx  = SUM(x),  sy = SUM(y),
               sxy = SUM(x*y), sxx = SUM(x*x)
        FROM src
        GROUP BY Platform, ServerName, VolumeName
    ),
    calc AS
    (
        SELECT l.Platform, l.ServerName, l.VolumeName,
               l.TotalBytes, l.UsedBytes, l.UsedPct,
               Slope = CASE WHEN r.n > 1 AND (r.n*r.sxx - r.sx*r.sx) <> 0
                            THEN (r.n*r.sxy - r.sx*r.sy) / (r.n*r.sxx - r.sx*r.sx)
                            ELSE NULL END              -- bytes/day
        FROM latest l
        JOIN reg r ON r.Platform = l.Platform AND r.ServerName = l.ServerName
                  AND r.VolumeName = l.VolumeName
        WHERE l.rn = 1
    )
    MERGE mon.DiskForecast AS tgt
    USING
    (
        SELECT Platform, ServerName, VolumeName, TotalBytes, UsedBytes, UsedPct,
               GrowthBytesPerDay = CASE WHEN Slope > 0 THEN CAST(Slope AS BIGINT) ELSE NULL END,
               DaysToFull        = CASE WHEN Slope > 0
                                        THEN CAST((TotalBytes - UsedBytes) / Slope AS INT)
                                        ELSE NULL END
        FROM calc
    ) AS s
    ON  tgt.Platform = s.Platform AND tgt.ServerName = s.ServerName
    AND tgt.VolumeName = s.VolumeName
    WHEN MATCHED THEN UPDATE SET
        tgt.TotalBytes        = s.TotalBytes,
        tgt.UsedBytes         = s.UsedBytes,
        tgt.UsedPct           = s.UsedPct,
        tgt.GrowthBytesPerDay = s.GrowthBytesPerDay,
        tgt.DaysToFull        = s.DaysToFull,
        tgt.ProjectedFullDate = CASE WHEN s.DaysToFull IS NOT NULL
                                     THEN DATEADD(DAY, s.DaysToFull, CAST(SYSUTCDATETIME() AS DATE)) END,
        tgt.RecommendedAddGB  = CASE WHEN s.GrowthBytesPerDay IS NOT NULL
                                     THEN CAST(CEILING(
                                          (s.GrowthBytesPerDay * @HeadroomDays * 1.0) / 1073741824.0) AS INT) END,
        tgt.Severity          = CASE WHEN s.DaysToFull IS NULL THEN 'OK'
                                     WHEN s.DaysToFull <= @CritDays THEN 'CRIT'
                                     WHEN s.DaysToFull <= @WarnDays THEN 'WARN'
                                     ELSE 'OK' END,
        tgt.ComputedAt        = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (Platform, ServerName, VolumeName, TotalBytes, UsedBytes, UsedPct,
         GrowthBytesPerDay, DaysToFull, ProjectedFullDate, RecommendedAddGB, Severity)
    VALUES
        (s.Platform, s.ServerName, s.VolumeName, s.TotalBytes, s.UsedBytes, s.UsedPct,
         s.GrowthBytesPerDay, s.DaysToFull,
         CASE WHEN s.DaysToFull IS NOT NULL
              THEN DATEADD(DAY, s.DaysToFull, CAST(SYSUTCDATETIME() AS DATE)) END,
         CASE WHEN s.GrowthBytesPerDay IS NOT NULL
              THEN CAST(CEILING((s.GrowthBytesPerDay * @HeadroomDays * 1.0) / 1073741824.0) AS INT) END,
         CASE WHEN s.DaysToFull IS NULL THEN 'OK'
              WHEN s.DaysToFull <= @CritDays THEN 'CRIT'
              WHEN s.DaysToFull <= @WarnDays THEN 'WARN'
              ELSE 'OK' END)
    -- drop forecast rows for volumes we no longer collect
    WHEN NOT MATCHED BY SOURCE THEN DELETE;

    INSERT cfg.CollectionLog (Collector, Status, RowsLoaded, Message)
    VALUES ('Forecast', 'OK', @@ROWCOUNT, 'DiskForecast refreshed');
END;
GO

/*---------------------------------------------------------------------------
  cfg.usp_Purge_History  -  trim time-series snapshots past retention.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_Purge_History
    @RetentionDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cut DATETIME2(0) = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());
    DELETE FROM mon.AGSyncStatus WHERE CollectedAt < @cut;
    DELETE FROM mon.DataLag      WHERE CollectedAt < @cut;
    DELETE FROM mon.DiskUsage    WHERE CollectedAt < @cut;
    DELETE FROM cfg.CollectionLog WHERE RunAt      < @cut;
END;
GO

PRINT 'Forecast + purge procs created.';
GO
