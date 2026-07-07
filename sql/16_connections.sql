/*==============================================================================
  DBADash  |  16 - DBeaver-style connections on cfg.Servers
  ----------------------------------------------------------------------------
  Adds connection fields so the dashboard "Servers" form can define HOW to
  connect, not just what to monitor:
    AuthType 'windows' (default, MSSQL) or 'sql' (SQL login / Redshift user)
    Host/Port/DatabaseName - used for Redshift (MSSQL uses ServerName itself)
    PasswordEnc - VARBINARY, encrypted with Windows DPAPI (LocalMachine scope)
                  by the dashboard box; only processes on that machine can
                  decrypt. The plaintext never touches the database.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO
IF COL_LENGTH('cfg.Servers','AuthType') IS NULL
    ALTER TABLE cfg.Servers ADD
        Host         NVARCHAR(256) NULL,
        Port         INT           NULL,
        DatabaseName NVARCHAR(128) NULL,
        AuthType     VARCHAR(10)   NOT NULL DEFAULT 'windows',
        UserName     NVARCHAR(128) NULL,
        PasswordEnc  VARBINARY(MAX) NULL;
GO

CREATE OR ALTER PROCEDURE cfg.usp_Server_Upsert
    @ServerName   SYSNAME,
    @Platform     VARCHAR(20)   = 'MSSQL',
    @Environment  VARCHAR(20)   = 'PROD',
    @FriendlyName NVARCHAR(128) = NULL,
    @IsActive     BIT           = 1,
    @Host         NVARCHAR(256) = NULL,
    @Port         INT           = NULL,
    @DatabaseName NVARCHAR(128) = NULL,
    @AuthType     VARCHAR(10)   = 'windows',
    @UserName     NVARCHAR(128) = NULL,
    @PasswordEnc  VARBINARY(MAX)= NULL     -- NULL = keep the stored password
AS
BEGIN
    SET NOCOUNT ON;
    IF @Platform NOT IN ('MSSQL','Redshift') SET @Platform = 'MSSQL';
    IF @AuthType NOT IN ('windows','sql')    SET @AuthType = 'windows';

    MERGE cfg.Servers AS t
    USING (SELECT ServerName = @ServerName) AS s ON t.ServerName = s.ServerName
    WHEN MATCHED THEN UPDATE SET
        Platform = @Platform, Environment = @Environment,
        FriendlyName = @FriendlyName, IsActive = @IsActive,
        Host = @Host, Port = @Port, DatabaseName = @DatabaseName,
        AuthType = @AuthType, UserName = @UserName,
        PasswordEnc = COALESCE(@PasswordEnc, t.PasswordEnc)
    WHEN NOT MATCHED THEN INSERT
        (ServerName, Platform, Environment, FriendlyName, IsActive,
         Host, Port, DatabaseName, AuthType, UserName, PasswordEnc)
        VALUES (@ServerName, @Platform, @Environment, @FriendlyName, @IsActive,
         @Host, @Port, @DatabaseName, @AuthType, @UserName, @PasswordEnc);

    SELECT ServerID, ServerName FROM cfg.Servers WHERE ServerName = @ServerName;
END;
GO

/* Expose connection info to the grid - but NEVER the password blob. */
CREATE OR ALTER VIEW rpt.Servers
AS
SELECT s.ServerID, s.ServerName, s.Platform, s.Environment, s.FriendlyName,
       s.IsActive, s.CreatedAt, s.Host, s.Port, s.DatabaseName,
       s.AuthType, s.UserName,
       HasPassword     = CAST(CASE WHEN s.PasswordEnc IS NOT NULL THEN 1 ELSE 0 END AS BIT),
       LastCollectedAt = lc.RunAt,
       LastStatus      = lc.Status,
       LastMessage     = lc.Message
FROM cfg.Servers s
OUTER APPLY (SELECT TOP (1) RunAt, Status, Message
             FROM cfg.CollectionLog l
             WHERE l.ServerName = s.ServerName ORDER BY l.RunAt DESC) lc;
GO
PRINT 'Connection model added to cfg.Servers (16).';
GO
