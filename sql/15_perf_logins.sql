/*==============================================================================
  DBADash  |  15 - Top queries, failed logins, login activity
  ----------------------------------------------------------------------------
  Phase 1 monitoring tables + views for basic performance and login auditing:
    - mon.TopQueries    : heaviest MSSQL statements (dm_exec_query_stats)
    - mon.FailedLogin   : failed logins, MSSQL + Redshift
    - mon.LoginActivity : who is connected from where (MSSQL sessions)
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('mon.TopQueries') IS NULL
CREATE TABLE mon.TopQueries
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    DatabaseName NVARCHAR(128) NULL,
    QueryText   NVARCHAR(500) NULL,
    ExecCount   BIGINT NULL,
    TotalCpuMs  BIGINT NULL,
    AvgCpuMs    BIGINT NULL,
    AvgDurMs    BIGINT NULL,
    AvgReads    BIGINT NULL,
    LastExec    DATETIME2(0) NULL
);
GO
IF OBJECT_ID('mon.FailedLogin') IS NULL
CREATE TABLE mon.FailedLogin
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Platform    VARCHAR(20)   NOT NULL,
    ServerName  SYSNAME       NOT NULL,
    EventTime   DATETIME2(0)  NULL,
    Message     NVARCHAR(500) NULL
);
GO
IF OBJECT_ID('mon.LoginActivity') IS NULL
CREATE TABLE mon.LoginActivity
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    LoginName   NVARCHAR(128) NULL,
    HostName    NVARCHAR(128) NULL,
    ProgramName NVARCHAR(160) NULL,
    SessionCount INT NULL,
    LastLogin   DATETIME2(0) NULL
);
GO

/*------------------------------ views --------------------------------------*/
CREATE OR ALTER VIEW rpt.TopQueries
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.TopQueries
)
SELECT ServerName, DatabaseName, QueryText, ExecCount, TotalCpuMs, AvgCpuMs,
       AvgDurMs, AvgReads, LastExec, CollectedAt
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.FailedLogins
AS
SELECT Platform, ServerName, EventTime, Message = MAX(Message), LastSeen = MAX(CollectedAt)
FROM mon.FailedLogin
WHERE EventTime >= DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY Platform, ServerName, EventTime, Message;
GO

CREATE OR ALTER VIEW rpt.LoginActivity
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.LoginActivity
)
SELECT ServerName, LoginName, HostName, ProgramName, SessionCount, LastLogin, CollectedAt
FROM latest WHERE rn = 1;
GO

PRINT 'Top queries / login audit objects created (15_perf_logins).';
GO
