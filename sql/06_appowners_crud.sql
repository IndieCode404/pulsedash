/*==============================================================================
  DBADash  |  06 - App Owner CRUD (backs the dashboard "update owner" form)
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*---------------------------------------------------------------------------
  cfg.usp_AppOwner_Upsert
  Insert or update by (ServerName, DatabaseName, AppName). Pass @AppOwnerID = 0
  for a brand new row. Returns the affected row so the UI can refresh in place.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_AppOwner_Upsert
    @AppOwnerID     INT           = 0,
    @ServerName     SYSNAME,
    @DatabaseName   SYSNAME       = '(instance)',
    @AppName        NVARCHAR(128),
    @Criticality    VARCHAR(10)   = 'Tier3',
    @PrimaryOwner   NVARCHAR(128) = NULL,
    @SecondaryOwner NVARCHAR(128) = NULL,
    @Team           NVARCHAR(128) = NULL,
    @Email          NVARCHAR(256) = NULL,
    @OnCallPhone    VARCHAR(40)   = NULL,
    @Notes          NVARCHAR(1000)= NULL,
    @UpdatedBy      NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @UpdatedBy = ISNULL(@UpdatedBy, SUSER_SNAME());

    IF @Criticality NOT IN ('Tier1','Tier2','Tier3')
        SET @Criticality = 'Tier3';

    MERGE cfg.AppOwners AS t
    USING (SELECT ID = NULLIF(@AppOwnerID,0),
                  ServerName = @ServerName,
                  DatabaseName = ISNULL(NULLIF(@DatabaseName,''),'(instance)'),
                  AppName = @AppName) AS s
    ON  (s.ID IS NOT NULL AND t.AppOwnerID = s.ID)
     OR (s.ID IS NULL AND t.ServerName = s.ServerName
                       AND t.DatabaseName = s.DatabaseName
                       AND t.AppName = s.AppName)
    WHEN MATCHED THEN UPDATE SET
        ServerName = @ServerName, DatabaseName = ISNULL(NULLIF(@DatabaseName,''),'(instance)'),
        AppName = @AppName, Criticality = @Criticality,
        PrimaryOwner = @PrimaryOwner, SecondaryOwner = @SecondaryOwner,
        Team = @Team, Email = @Email, OnCallPhone = @OnCallPhone, Notes = @Notes,
        UpdatedBy = @UpdatedBy, UpdatedAt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (ServerName, DatabaseName, AppName, Criticality, PrimaryOwner, SecondaryOwner,
         Team, Email, OnCallPhone, Notes, UpdatedBy)
        VALUES (@ServerName, ISNULL(NULLIF(@DatabaseName,''),'(instance)'), @AppName,
         @Criticality, @PrimaryOwner, @SecondaryOwner, @Team, @Email, @OnCallPhone,
         @Notes, @UpdatedBy);

    SELECT * FROM rpt.AppOwners
    WHERE ServerName = @ServerName
      AND DatabaseName = ISNULL(NULLIF(@DatabaseName,''),'(instance)')
      AND AppName = @AppName;
END;
GO

/*---------------------------------------------------------------------------
  cfg.usp_AppOwner_Delete
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_AppOwner_Delete
    @AppOwnerID INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM cfg.AppOwners WHERE AppOwnerID = @AppOwnerID;
    SELECT RowsDeleted = @@ROWCOUNT;
END;
GO

PRINT 'App owner CRUD procs created.';
GO
