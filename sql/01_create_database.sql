/*==============================================================================
  DBADash  |  01 - Create central monitoring database
  ----------------------------------------------------------------------------
  Run this ONCE on your central monitoring instance (the box that hosts the
  CMS / that you will point Power BI / the HTML dashboard at).

  Everything else in this kit lives inside the [DBADash] database.
==============================================================================*/
SET NOCOUNT ON;
GO

IF DB_ID('DBADash') IS NULL
BEGIN
    PRINT 'Creating database [DBADash]...';
    CREATE DATABASE [DBADash];
END
ELSE
    PRINT '[DBADash] already exists - skipping create.';
GO

ALTER DATABASE [DBADash] SET RECOVERY SIMPLE;   -- monitoring data is disposable
GO

USE [DBADash];
GO

-- Schemas keep collectors, staging and reporting objects tidy.
IF SCHEMA_ID('mon')  IS NULL EXEC('CREATE SCHEMA mon;');   -- monitoring data (time series)
IF SCHEMA_ID('cfg')  IS NULL EXEC('CREATE SCHEMA cfg;');   -- configuration / inventory
IF SCHEMA_ID('rpt')  IS NULL EXEC('CREATE SCHEMA rpt;');   -- reporting views for dashboards
GO

PRINT 'Database + schemas ready.';
GO
