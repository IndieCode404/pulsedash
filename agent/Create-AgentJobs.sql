/*==============================================================================
  DBADash  |  SQL Agent job - schedules the collector
  ----------------------------------------------------------------------------
  Creates job "DBADash - Collect" that runs deploy\Collect-All.ps1 on a
  schedule. Runs as the SQL Agent service account, so that account needs:
    - VIEW SERVER STATE on every monitored MSSQL instance (for the DMVs)
    - db_datawriter on DBADash
    - network/ODBC access to Redshift (or use a proxy credential)

  EDIT @ScriptPath and @IntervalMinutes below before running.
==============================================================================*/
USE [msdb];
GO
SET NOCOUNT ON;

DECLARE @JobName        SYSNAME      = N'DBADash - Collect';
DECLARE @ScriptPath     NVARCHAR(400)= N'K:\DBA_Monitoring\DBADash\deploy\Collect-All.ps1';
DECLARE @IntervalMinutes INT         = 15;
DECLARE @OwnerLogin     SYSNAME      = SUSER_SNAME();

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

DECLARE @jobId BINARY(16);
EXEC msdb.dbo.sp_add_job
     @job_name = @JobName,
     @description = N'DBADash: collect AG sync, data lag, disk usage (MSSQL + Redshift) into DBADash.',
     @owner_login_name = @OwnerLogin,
     @job_id = @jobId OUTPUT;

-- Run PowerShell via CmdExec. -File avoids quoting headaches with the path.
DECLARE @cmd NVARCHAR(1000) =
    N'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + @ScriptPath + N'"';

EXEC msdb.dbo.sp_add_jobstep
     @job_id = @jobId,
     @step_name = N'Run Collect-All.ps1',
     @subsystem = N'CmdExec',
     @command = @cmd,
     @on_success_action = 1,   -- quit with success
     @on_fail_action    = 2;   -- quit with failure

DECLARE @schedName SYSNAME = N'DBADash - Every ' + CAST(@IntervalMinutes AS NVARCHAR(10)) + N' min';
EXEC msdb.dbo.sp_add_jobschedule
     @job_id = @jobId,
     @name = @schedName,
     @freq_type = 4,                       -- daily
     @freq_interval = 1,
     @freq_subday_type = 4,                -- minutes
     @freq_subday_interval = @IntervalMinutes,
     @active_start_time = 000500;          -- 00:05:00

EXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(LOCAL)';

PRINT 'Job "' + @JobName + '" created - runs every ' + CAST(@IntervalMinutes AS VARCHAR) + ' minutes.';
GO
