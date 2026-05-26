:ON ERROR EXIT
SET NOCOUNT ON;
SET XACT_ABORT ON;

PRINT '============================================================';
PRINT 'DBCUSTODIO - Crear BDs origen, etiquetar con SP y generar backups';
PRINT '============================================================';

USE [master];
GO

IF DB_ID(N'dbdba') IS NULL
BEGIN
    RAISERROR('No existe dbdba. Ejecute primero run_init_DBCUSTODIO.ps1.', 16, 1);
    RETURN;
END;
GO

IF OBJECT_ID(N'dbdba.noprod.SP_ETIQUETAR_BASES', N'P') IS NULL
BEGIN
    RAISERROR('No existe dbdba.noprod.SP_ETIQUETAR_BASES. Ejecute primero 05_Caducidad_Tablas.sql.', 16, 1);
    RETURN;
END;
GO

/* ---- Crear o recrear BDs origen en DBCUSTODIO ---- */
DECLARE @Hoy        date         = CAST(GETDATE() AS date);
DECLARE @sql        nvarchar(max);
DECLARE @NombreBase sysname;

DECLARE curBases CURSOR LOCAL FAST_FORWARD FOR
SELECT n FROM (VALUES
    (N'Activa_Etiquetada_RSE'),
    (N'Offline_SinEtiqueta'),
    (N'SinBackup'),
    (N'Offline_Etiquetada_RE'),
    (N'Activa_SinEtiqueta'),
    (N'Activa_Etiquetada_RE'),
    (N'Offline_Etiquetada_RSE'),
    (N'Activa_Vencida_Ayer'),
    (N'Activa_Vence_Hoy')
) AS t(n);

OPEN curBases;
FETCH NEXT FROM curBases INTO @NombreBase;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '--- Preparando BD origen: ' + @NombreBase;

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

    SET @sql = N'CREATE DATABASE ' + QUOTENAME(@NombreBase) + N';';
    EXEC(@sql);

    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@NombreBase) + N' SET RECOVERY SIMPLE;';
    EXEC(@sql);

    FETCH NEXT FROM curBases INTO @NombreBase;
END;
CLOSE curBases;
DEALLOCATE curBases;
GO

/* ---- Limpiar logs anteriores ---- */
USE [dbdba];
GO

DELETE FROM noprod.LOG_ETIQUETADO_BASES
WHERE DatabaseName IN (
    N'Activa_Etiquetada_RSE', N'Offline_Etiquetada_RSE',
    N'Activa_Etiquetada_RE',  N'Offline_Etiquetada_RE',
    N'Activa_Vencida_Ayer',   N'Activa_Vence_Hoy'
);
GO

/* ---- Etiquetar con SP_ETIQUETAR_BASES ---- */
/* Todas las variables y EXECs en un solo bloque sin GO intermedio */
DECLARE @FechaFutura date = DATEADD(DAY,  15, CAST(GETDATE() AS date));
DECLARE @FechaVencida date = DATEADD(DAY,  -5, CAST(GETDATE() AS date));
DECLARE @FechaAyer    date = DATEADD(DAY,  -1, CAST(GETDATE() AS date));
DECLARE @FechaHoy     date = CAST(GETDATE() AS date);

PRINT '--- SP_ETIQUETAR_BASES: RSE activa (vence en 15 dias)';
EXEC dbdba.noprod.SP_ETIQUETAR_BASES
    @DatabaseList = N'Activa_Etiquetada_RSE',
    @Caso         = N'5100',
    @DBA          = N'dba1',
    @Razon        = 'RSE',
    @Responsable  = N'Ana Morales',
    @FechaExpira  = @FechaFutura;

PRINT '--- SP_ETIQUETAR_BASES: RSE offline (vencida hace 5 dias)';
EXEC dbdba.noprod.SP_ETIQUETAR_BASES
    @DatabaseList = N'Offline_Etiquetada_RSE',
    @Caso         = N'5100',
    @DBA          = N'dba1',
    @Razon        = 'RSE',
    @Responsable  = N'Ana Morales',
    @FechaExpira  = @FechaVencida,
    @AllowPast    = 1;

PRINT '--- SP_ETIQUETAR_BASES: RE activa';
EXEC dbdba.noprod.SP_ETIQUETAR_BASES
    @DatabaseList = N'Activa_Etiquetada_RE',
    @Caso         = N'35101',
    @DBA          = N'dba2',
    @Razon        = 'RE',
    @Responsable  = N'Luis Paredes';

PRINT '--- SP_ETIQUETAR_BASES: RE offline';
EXEC dbdba.noprod.SP_ETIQUETAR_BASES
    @DatabaseList = N'Offline_Etiquetada_RE',
    @Caso         = N'35101',
    @DBA          = N'dba2',
    @Razon        = 'RE',
    @Responsable  = N'Luis Paredes';

PRINT '--- SP_ETIQUETAR_BASES: RSE vencida ayer';
EXEC dbdba.noprod.SP_ETIQUETAR_BASES
    @DatabaseList = N'Activa_Vencida_Ayer',
    @Caso         = N'7777',
    @DBA          = N'dba1',
    @Razon        = 'RSE',
    @Responsable  = N'Pruebas Caducidad',
    @FechaExpira  = @FechaAyer,
    @AllowPast    = 1;

PRINT '--- SP_ETIQUETAR_BASES: RSE vence hoy';
EXEC dbdba.noprod.SP_ETIQUETAR_BASES
    @DatabaseList = N'Activa_Vence_Hoy',
    @Caso         = N'8888',
    @DBA          = N'dba1',
    @Razon        = 'RSE',
    @Responsable  = N'Pruebas Caducidad',
    @FechaExpira  = @FechaHoy,
    @AllowPast    = 1;

/* ---- Ajustar fechas del LOG para simular historial coherente ---- */
UPDATE noprod.LOG_ETIQUETADO_BASES
SET ExecutedAt = DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -13, CAST(GETDATE() AS date)) AS datetime2(0)))
WHERE DatabaseName = N'Activa_Etiquetada_RSE';

UPDATE noprod.LOG_ETIQUETADO_BASES
SET ExecutedAt = DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -6, CAST(GETDATE() AS date)) AS datetime2(0)))
WHERE DatabaseName = N'Offline_Etiquetada_RSE';

UPDATE noprod.LOG_ETIQUETADO_BASES
SET ExecutedAt = DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -9, CAST(GETDATE() AS date)) AS datetime2(0)))
WHERE DatabaseName = N'Activa_Etiquetada_RE';

UPDATE noprod.LOG_ETIQUETADO_BASES
SET ExecutedAt = DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -26, CAST(GETDATE() AS date)) AS datetime2(0)))
WHERE DatabaseName = N'Offline_Etiquetada_RE';

UPDATE noprod.LOG_ETIQUETADO_BASES
SET ExecutedAt = DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -2, CAST(GETDATE() AS date)) AS datetime2(0)))
WHERE DatabaseName = N'Activa_Vencida_Ayer';

UPDATE noprod.LOG_ETIQUETADO_BASES
SET ExecutedAt = DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -1, CAST(GETDATE() AS date)) AS datetime2(0)))
WHERE DatabaseName = N'Activa_Vence_Hoy';
GO

/* ---- Generar backups en volumen compartido ---- */
USE [master];
GO

IF OBJECT_ID('tempdb..#BasesBackup') IS NOT NULL DROP TABLE #BasesBackup;
CREATE TABLE #BasesBackup
(
    NombreBase       sysname      NOT NULL PRIMARY KEY,
    TieneBackup      bit          NOT NULL,
    BackupStartDate  datetime2(0) NULL,
    BackupFinishDate datetime2(0) NULL
);

DECLARE @Hoy date = CAST(GETDATE() AS date);
INSERT INTO #BasesBackup (NombreBase, TieneBackup, BackupStartDate, BackupFinishDate)
VALUES
(N'Activa_Etiquetada_RSE',  1, DATEADD(MINUTE,  0, CAST(DATEADD(DAY, -12, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 15, CAST(DATEADD(DAY, -12, @Hoy) AS datetime2(0)))),
(N'Offline_SinEtiqueta',    1, DATEADD(MINUTE, 10, CAST(DATEADD(DAY, -45, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 25, CAST(DATEADD(DAY, -45, @Hoy) AS datetime2(0)))),
(N'SinBackup',              0, NULL, NULL),
(N'Offline_Etiquetada_RE',  1, DATEADD(MINUTE, 20, CAST(DATEADD(DAY, -25, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 35, CAST(DATEADD(DAY, -25, @Hoy) AS datetime2(0)))),
(N'Activa_SinEtiqueta',     1, DATEADD(MINUTE, 30, CAST(DATEADD(DAY, -18, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 45, CAST(DATEADD(DAY, -18, @Hoy) AS datetime2(0)))),
(N'Activa_Etiquetada_RE',   1, DATEADD(MINUTE, 40, CAST(DATEADD(DAY,  -8, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 55, CAST(DATEADD(DAY,  -8, @Hoy) AS datetime2(0)))),
(N'Offline_Etiquetada_RSE', 1, DATEADD(MINUTE, 50, CAST(DATEADD(DAY,  -5, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 65, CAST(DATEADD(DAY,  -5, @Hoy) AS datetime2(0)))),
(N'Activa_Vencida_Ayer',    1, DATEADD(MINUTE,  0, CAST(DATEADD(DAY, -10, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 15, CAST(DATEADD(DAY, -10, @Hoy) AS datetime2(0)))),
(N'Activa_Vence_Hoy',       1, DATEADD(MINUTE,  0, CAST(DATEADD(DAY,  -3, @Hoy) AS datetime2(0))), DATEADD(MINUTE, 15, CAST(DATEADD(DAY,  -3, @Hoy) AS datetime2(0))));

DECLARE
    @NombreBase      sysname,
    @TieneBackup     bit,
    @BackupStartDate datetime2(0),
    @BackupFinishDate datetime2(0),
    @backupFile      nvarchar(4000),
    @sql             nvarchar(max),
    @backupSetId     int;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
SELECT NombreBase, TieneBackup, BackupStartDate, BackupFinishDate
FROM #BasesBackup ORDER BY NombreBase;

OPEN c;
FETCH NEXT FROM c INTO @NombreBase, @TieneBackup, @BackupStartDate, @BackupFinishDate;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @TieneBackup = 1
    BEGIN
        SET @backupFile = N'/var/opt/mssql/shared/' + @NombreBase + N'.bak';

        PRINT 'Backup: ' + @NombreBase + ' -> ' + @backupFile;
        SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@NombreBase) +
                   N' TO DISK = N''' + REPLACE(@backupFile, '''', '''''') +
                   N''' WITH INIT, COPY_ONLY, CHECKSUM;';
        EXEC(@sql);

        SELECT TOP 1 @backupSetId = backup_set_id
        FROM msdb.dbo.backupset
        WHERE database_name = @NombreBase
        ORDER BY backup_finish_date DESC, backup_set_id DESC;

        IF @backupSetId IS NULL
        BEGIN
            RAISERROR('No se pudo obtener backup_set_id para %s.', 16, 1, @NombreBase);
            RETURN;
        END;

        UPDATE msdb.dbo.backupset
        SET backup_start_date  = @BackupStartDate,
            backup_finish_date = @BackupFinishDate
        WHERE backup_set_id = @backupSetId;

        PRINT '  -> Fechas ajustadas en msdb.dbo.backupset.';
    END
    ELSE
        PRINT 'SinBackup: no se genera .bak (caso sin historial de backup).';

    FETCH NEXT FROM c INTO @NombreBase, @TieneBackup, @BackupStartDate, @BackupFinishDate;
END;
CLOSE c;
DEALLOCATE c;

PRINT '';
PRINT '============================================================';
PRINT 'Backups generados. Resumen BDs origen:';
PRINT '============================================================';

SELECT
    d.name              AS DatabaseName,
    d.state_desc,
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.user_name        AS backup_user
FROM sys.databases d
OUTER APPLY (
    SELECT TOP 1 backup_start_date, backup_finish_date, user_name
    FROM msdb.dbo.backupset
    WHERE database_name = d.name
    ORDER BY backup_finish_date DESC
) bs
WHERE d.name IN (
    N'Activa_Etiquetada_RSE', N'Activa_Etiquetada_RE',   N'Activa_SinEtiqueta',
    N'Offline_Etiquetada_RSE', N'Offline_Etiquetada_RE', N'Offline_SinEtiqueta',
    N'SinBackup', N'Activa_Vencida_Ayer', N'Activa_Vence_Hoy'
)
ORDER BY d.name;