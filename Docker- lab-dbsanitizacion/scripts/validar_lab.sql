:ON ERROR EXIT
SET NOCOUNT ON;

DECLARE @LabId int = $(LAB_ID);

IF OBJECT_ID('tempdb..#BasesLab') IS NOT NULL DROP TABLE #BasesLab;
CREATE TABLE #BasesLab
(
    LabId int NOT NULL,
    NombreBase sysname NOT NULL,
    Caso varchar(120) NOT NULL,
    EsperadoEstado varchar(20) NOT NULL,
    EsperadoBackup bit NOT NULL
);

INSERT INTO #BasesLab (LabId, NombreBase, Caso, EsperadoEstado, EsperadoBackup)
VALUES
(1, N'Activa_Etiquetada_RSE',  'Activa + RSE + backup/restorehistory',              'ONLINE',  1),
(1, N'Offline_SinEtiqueta',    'Offline + sin etiqueta + backup/restorehistory',     'OFFLINE', 1),
(1, N'SinBackup',              'Activa + sin registro backup/restorehistory',        'ONLINE',  0),
(2, N'Offline_Etiquetada_RE',  'Offline + RE + backup/restorehistory',               'OFFLINE', 1),
(2, N'Activa_SinEtiqueta',     'Activa + sin etiqueta + backup/restorehistory',      'ONLINE',  1),
(3, N'Activa_Etiquetada_RE',   'Activa + RE + backup/restorehistory',                'ONLINE',  1),
(3, N'Offline_Etiquetada_RSE', 'Offline + RSE + backup/restorehistory',              'OFFLINE', 1);

;WITH UltimoRestore AS
(
    SELECT
        rh.destination_database_name,
        rh.restore_date,
        rh.user_name,
        bs.database_name AS backup_database_name,
        bs.backup_start_date,
        bs.backup_finish_date,
        bs.type AS BackupType,
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
    b.LabId,
    b.NombreBase,
    b.Caso,
    b.EsperadoEstado,
    d.state_desc AS EstadoActual,
    b.EsperadoBackup,
    CASE WHEN ur.destination_database_name IS NULL THEN 0 ELSE 1 END AS TieneRestoreHistory,
    ur.restore_date,
    ur.user_name,
    ur.backup_database_name,
    ur.backup_start_date,
    ur.backup_finish_date,
    ur.BackupType
FROM #BasesLab b
LEFT JOIN sys.databases d
    ON d.name = b.NombreBase
LEFT JOIN UltimoRestore ur
    ON ur.destination_database_name = b.NombreBase
   AND ur.rn = 1
WHERE b.LabId = @LabId
ORDER BY b.NombreBase;
