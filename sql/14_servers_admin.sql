/*==============================================================================
  DBADash  |  14 - Server inventory admin (backs the dashboard "Servers" tab)
  ----------------------------------------------------------------------------
  Lets you add/deactivate monitored servers from the dashboard UI instead of
  editing config. Collect-All.ps1 reads ACTIVE MSSQL rows from cfg.Servers as a
  third target source (alongside the CMS group and the config list).

  NOTE: credentials never live in this table. UI-added MSSQL servers are
  reached with Windows/integrated auth; SQL-auth targets and Redshift
  credentials belong in deploy\config\dbadash.json.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE cfg.usp_Server_Upsert
    @ServerName   SYSNAME,
    @Platform     VARCHAR(20)  = 'MSSQL',
    @Environment  VARCHAR(20)  = 'PROD',
    @FriendlyName NVARCHAR(128)= NULL,
    @IsActive     BIT          = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Platform NOT IN ('MSSQL','Redshift') SET @Platform = 'MSSQL';

    MERGE cfg.Servers AS t
    USING (SELECT ServerName = @ServerName) AS s ON t.ServerName = s.ServerName
    WHEN MATCHED THEN UPDATE SET
        Platform = @Platform, Environment = @Environment,
        FriendlyName = @FriendlyName, IsActive = @IsActive
    WHEN NOT MATCHED THEN INSERT (ServerName, Platform, Environment, FriendlyName, IsActive)
        VALUES (@ServerName, @Platform, @Environment, @FriendlyName, @IsActive);

    SELECT * FROM cfg.Servers WHERE ServerName = @ServerName;
END;
GO

CREATE OR ALTER PROCEDURE cfg.usp_Server_Delete
    @ServerID INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM cfg.Servers WHERE ServerID = @ServerID;
    SELECT RowsDeleted = @@ROWCOUNT;
END;
GO

/*---------------------------------------------------------------------------
  rpt.Servers  -  inventory + last collection result per server, for the grid.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.Servers
AS
SELECT s.ServerID, s.ServerName, s.Platform, s.Environment, s.FriendlyName,
       s.IsActive, s.CreatedAt,
       LastCollectedAt = lc.RunAt,
       LastStatus      = lc.Status,
       LastMessage     = lc.Message
FROM cfg.Servers s
OUTER APPLY (SELECT TOP (1) RunAt, Status, Message
             FROM cfg.CollectionLog l
             WHERE l.ServerName = s.ServerName
             ORDER BY l.RunAt DESC) lc;
GO

PRINT 'Server admin objects created (14_servers_admin).';
GO
