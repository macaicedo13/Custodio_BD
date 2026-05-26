:ON ERROR EXIT
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @LabId int = $(LAB_ID);
DECLARE @RestoreBy sysname = N'$(RESTORE_BY)';

PRINT '============================================================';
PRINT 'SEED LAB DISTRIBUIDO - RESTORE DESDE BACKUPS DBCUSTODIO';
PRINT 'LabId     : ' + CONVERT(varchar(10), @LabId);
PRINT 'RestoreBy : ' + @RestoreBy;
PRINT '============================================================';

IF @RestoreBy NOT IN (N'dba1', N'dba2')
BEGIN
    RAISERROR('RESTORE_BY invalido. Use dba1 o dba2.', 16, 1);
    RETURN;
END;

IF OBJECT_ID('tempdb..#PlanLab') IS NOT NULL DROP TABLE #PlanLab;
CREATE TABLE #PlanLab
(
    LabId               int          NOT NULL,
    NombreBase          sysname      NOT NULL,
    EsperadoEstado      varchar(20)  NOT NULL,
    TieneBackup         bit          NOT NULL,
    RestoreBy           sysname      NOT NULL,
    BackupStartDate     datetime2(0) NULL,
    BackupFinishDate    datetime2(0) NULL,
    RestoreDate         datetime2(0) NULL,
    Caso                varchar(200) NOT NULL,
    CONSTRAINT PK_PlanLab PRIMARY KEY (LabId, NombreBase)
);

DECLARE @Hoy date = CAST(GETDATE() AS date);

INSERT INTO #PlanLab
(
    LabId, NombreBase, EsperadoEstado, TieneBackup, RestoreBy,
    BackupStartDate, BackupFinishDate, RestoreDate, Caso
)
VALUES
(1, N'Activa_Etiquetada_RSE',  'ONLINE',  1, N'dba1', DATEADD(MINUTE,  0, CAST(DATEADD(DAY, -12, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 15, CAST(DATEADD(DAY, -12, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -12, @Hoy) AS datetime2(0))), 'Activa + RSE + backup/restorehistory'),
(1, N'Offline_SinEtiqueta',    'OFFLINE', 1, N'dba2', DATEADD(MINUTE, 10, CAST(DATEADD(DAY, -45, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 25, CAST(DATEADD(DAY, -45, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 40, CAST(DATEADD(DAY, -45, @Hoy) AS datetime2(0))), 'Offline + sin etiqueta + backup/restorehistory'),
(1, N'SinBackup',              'ONLINE',  0, N'dba1', NULL, NULL, NULL, 'Activa + sin registro backup/restorehistory'),
(1, N'Activa_Vencida_Ayer',    'ONLINE',  1, N'dba1', DATEADD(MINUTE,  0, CAST(DATEADD(DAY, -10, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 15, CAST(DATEADD(DAY, -10, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -10, @Hoy) AS datetime2(0))), 'Activa + RSE + fecha vencida ayer'),
(1, N'Activa_Vence_Hoy',       'ONLINE',  1, N'dba1', DATEADD(MINUTE,  0, CAST(DATEADD(DAY,  -3, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 15, CAST(DATEADD(DAY,  -3, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 30, CAST(DATEADD(DAY,  -3, @Hoy) AS datetime2(0))), 'Activa + RSE + vence hoy'),
(2, N'Offline_Etiquetada_RE',  'OFFLINE', 1, N'dba2', DATEADD(MINUTE, 20, CAST(DATEADD(DAY, -25, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 35, CAST(DATEADD(DAY, -25, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 50, CAST(DATEADD(DAY, -25, @Hoy) AS datetime2(0))), 'Offline + RE + backup/restorehistory'),
(2, N'Activa_SinEtiqueta',     'ONLINE',  1, N'dba1', DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -18, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 45, CAST(DATEADD(DAY, -18, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 60, CAST(DATEADD(DAY, -18, @Hoy) AS datetime2(0))), 'Activa + sin etiqueta + backup/restorehistory'),
(3, N'Activa_Etiquetada_RE',   'ONLINE',  1, N'dba2', DATEADD(MINUTE, 40, CAST(DATEADD(DAY,  -8, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 55, CAST(DATEADD(DAY,  -8, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 70, CAST(DATEADD(DAY,  -8, @Hoy) AS datetime2(0))), 'Activa + RE + backup/restorehistory'),
(3, N'Offline_Etiquetada_RSE', 'OFFLINE', 1, N'dba1', DATEADD(MINUTE, 50, CAST(DATEADD(DAY,  -5, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 65, CAST(DATEADD(DAY,  -5, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 80, CAST(DATEADD(DAY,  -5, @Hoy) AS datetime2(0))), 'Offline + RSE + backup/restorehistory');

DECLARE
    @NombreBase sysname,
    @EsperadoEstado varchar(20),
    @TieneBackup bit,
    @BackupStartDate datetime2(0),
    @BackupFinishDate datetime2(0),
    @RestoreDate datetime2(0),
    @BackupFile nvarchar(4000),
    @DataFile nvarchar(4000),
    @LogFile nvarchar(4000),
    @DataLogical sysname,
    @LogLogical sysname,
    @sql nvarchar(max),
    @backupSetId int,
    @restoreHistoryId int;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
SELECT NombreBase, EsperadoEstado, TieneBackup, BackupStartDate, BackupFinishDate, RestoreDate
FROM #PlanLab
WHERE LabId = @LabId
  AND RestoreBy = @RestoreBy
ORDER BY NombreBase;

OPEN c;
FETCH NEXT FROM c INTO @NombreBase, @EsperadoEstado, @TieneBackup, @BackupStartDate, @BackupFinishDate, @RestoreDate;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '------------------------------------------------------------';
    PRINT 'Preparando ' + @NombreBase + ' en LAB ' + CONVERT(varchar(10), @LabId) + ' con usuario ' + @RestoreBy;

    IF DB_ID(@NombreBase) IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @NombreBase AND state_desc = 'OFFLINE')
        BEGIN
            SET @sql = N'ALTER DATABASE ' + QUOTENAME(@NombreBase) + N' SET ONLINE WITH ROLLBACK IMMEDIATE;';
            EXEC(@sql);
        END;

        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@NombreBase) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@NombreBase) + N';';
        EXEC(@sql);
    END;

    EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = @NombreBase;

    IF @TieneBackup = 1
    BEGIN
        SET @BackupFile = N'/var/opt/mssql/shared/' + @NombreBase + N'.bak';
        SET @DataFile = N'/var/opt/mssql/data/' + @NombreBase + N'.mdf';
        SET @LogFile  = N'/var/opt/mssql/data/' + @NombreBase + N'_log.ldf';
        SET @DataLogical = @NombreBase;
        SET @LogLogical  = @NombreBase + N'_log';

        SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@NombreBase) + N'
            FROM DISK = N''' + REPLACE(@BackupFile, '''', '''''') + N'''
            WITH REPLACE, RECOVERY,
                 MOVE N''' + REPLACE(@DataLogical, '''', '''''') + N''' TO N''' + REPLACE(@DataFile, '''', '''''') + N''',
                 MOVE N''' + REPLACE(@LogLogical, '''', '''''') + N''' TO N''' + REPLACE(@LogFile, '''', '''''') + N''';';
        EXEC(@sql);

        SELECT TOP (1)
            @restoreHistoryId = rh.restore_history_id,
            @backupSetId = rh.backup_set_id
        FROM msdb.dbo.restorehistory rh
        WHERE rh.destination_database_name = @NombreBase
        ORDER BY rh.restore_date DESC, rh.restore_history_id DESC;

        IF @restoreHistoryId IS NULL OR @backupSetId IS NULL
        BEGIN
            RAISERROR('No se pudo encontrar restorehistory/backupset para %s.', 16, 1, @NombreBase);
            RETURN;
        END;

        UPDATE msdb.dbo.backupset
        SET backup_start_date = @BackupStartDate,
            backup_finish_date = @BackupFinishDate
        WHERE backup_set_id = @backupSetId;

        UPDATE msdb.dbo.restorehistory
        SET restore_date = @RestoreDate,
            user_name = @RestoreBy
        WHERE restore_history_id = @restoreHistoryId;
    END
    ELSE
    BEGIN
        SET @sql = N'CREATE DATABASE ' + QUOTENAME(@NombreBase) + N';';
        EXEC(@sql);

        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@NombreBase) + N' SET RECOVERY SIMPLE;';
        EXEC(@sql);

    END;

    IF @EsperadoEstado = 'OFFLINE'
    BEGIN
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@NombreBase) + N' SET OFFLINE WITH ROLLBACK IMMEDIATE;';
        EXEC(@sql);
    END;
    ELSE
    BEGIN
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@NombreBase) + N' SET MULTI_USER;';
        EXEC(@sql);
    END;

    FETCH NEXT FROM c INTO @NombreBase, @EsperadoEstado, @TieneBackup, @BackupStartDate, @BackupFinishDate, @RestoreDate;
END;

CLOSE c;
DEALLOCATE c;

PRINT '============================================================';
PRINT 'Resumen LAB ' + CONVERT(varchar(10), @LabId) + ' / RestoreBy ' + @RestoreBy;
PRINT '============================================================';

;WITH UltimoRestore AS
(
    SELECT
        rh.destination_database_name,
        rh.restore_date,
        rh.user_name,
        bs.database_name AS backup_database_name,
        bs.backup_start_date,
        bs.backup_finish_date,
        ROW_NUMBER() OVER
        (
            PARTITION BY rh.destination_database_name
            ORDER BY rh.restore_date DESC, rh.restore_history_id DESC
        ) AS rn
    FROM msdb.dbo.restorehistory rh
    INNER JOIN msdb.dbo.backupset bs
        ON rh.backup_set_id = bs.backup_set_id
)
SELECT
    p.LabId,
    p.NombreBase,
    p.Caso,
    p.RestoreBy,
    p.EsperadoEstado,
    d.state_desc AS EstadoActual,
    p.TieneBackup,
    ur.restore_date,
    ur.user_name,
    ur.backup_database_name,
    ur.backup_start_date,
    ur.backup_finish_date
FROM #PlanLab p
LEFT JOIN sys.databases d
    ON d.name = p.NombreBase
LEFT JOIN UltimoRestore ur
    ON ur.destination_database_name = p.NombreBase
   AND ur.rn = 1
WHERE p.LabId = @LabId
  AND p.RestoreBy = @RestoreBy
ORDER BY p.NombreBase;
