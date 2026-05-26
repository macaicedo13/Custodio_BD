SET NOCOUNT ON;

PRINT '============================================================';
PRINT 'VALIDACION DBCUSTODIO';
PRINT '============================================================';

SELECT
    name AS DatabaseName,
    state_desc
FROM sys.databases
WHERE name = N'dbdba';

USE [dbdba];
GO

PRINT '--- Esquemas ---';
SELECT name AS SchemaName
FROM sys.schemas
WHERE name IN (N'dbo', N'noprod')
ORDER BY name;

PRINT '--- Tablas creadas ---';
SELECT
    s.name AS SchemaName,
    t.name AS TableName
FROM sys.tables t
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE
    (s.name = N'dbo' AND t.name IN (N'servidores', N'instancias'))
    OR
    (s.name = N'noprod' AND t.name IN (N'LOG_ETIQUETADO_BASES', N'INVENTARIO_BASES', N'HISTORIAL_BASES'))
ORDER BY s.name, t.name;


PRINT '--- Datos dbo.servidores ---';
SELECT
    DireccionIP,
    Hostname,
    Ambiente,
    Version_SO,
    Fecha_actualiza,
    estado
FROM dbo.servidores
ORDER BY DireccionIP;

PRINT '--- Datos dbo.instancias ---';
SELECT
    ID_instancia,
    IP_server,
    SERVER_TO_PROD,
    Puerto,
    instancia_name,
    Ambiente,
    Estado,
    RESPONSABLE
FROM dbo.instancias
ORDER BY ID_instancia;

PRINT '--- Procedimientos creados ---';
SELECT
    s.name AS SchemaName,
    p.name AS ProcedureName
FROM sys.procedures p
INNER JOIN sys.schemas s ON s.schema_id = p.schema_id
WHERE s.name = N'noprod'
ORDER BY p.name;

PRINT '--- Usuarios dbdba gestionados por el laboratorio ---';
SELECT name AS UserName, type_desc
FROM sys.database_principals
WHERE name IN (N'svc_caducidad')
ORDER BY name;


PRINT '--- Permisos svc_caducidad ---';
SELECT
    USER_NAME(dp.grantee_principal_id) AS PrincipalName,
    dp.permission_name,
    dp.state_desc,
    COALESCE(OBJECT_SCHEMA_NAME(dp.major_id) + N'.' + OBJECT_NAME(dp.major_id), DB_NAME()) AS SecurableName
FROM sys.database_permissions dp
WHERE USER_NAME(dp.grantee_principal_id) = N'svc_caducidad'
ORDER BY SecurableName, dp.permission_name;
GO

USE [master];
GO

PRINT '--- BDs origen de laboratorio en DBCUSTODIO ---';
SELECT
    d.name AS DatabaseName,
    d.state_desc,
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.user_name AS backup_user_name
FROM sys.databases d
OUTER APPLY
(
    SELECT TOP (1)
        backup_start_date,
        backup_finish_date,
        user_name
    FROM msdb.dbo.backupset bs
    WHERE bs.database_name = d.name
    ORDER BY backup_finish_date DESC, backup_set_id DESC
) bs
WHERE d.name IN
(
    N'Activa_Etiquetada_RSE', N'Activa_Etiquetada_RE', N'Activa_SinEtiqueta',
    N'Offline_Etiquetada_RSE', N'Offline_Etiquetada_RE', N'Offline_SinEtiqueta',
    N'SinBackup'
)
ORDER BY d.name;
GO

USE [dbdba];
GO

PRINT '--- LOG_ETIQUETADO_BASES generado por SP_ETIQUETAR_BASES ---';
SELECT
    LogID,
    ExecutionID,
    ExecutedAt,
    ExecutedBy,
    DatabaseName,
    PropertyName,
    PropertyValue,
    Caso,
    DBA,
    RazonCodigo,
    Responsable,
    FechaExpiracion,
    Action,
    Status
FROM noprod.LOG_ETIQUETADO_BASES
WHERE DatabaseName IN
(
    N'Activa_Etiquetada_RSE',
    N'Offline_Etiquetada_RSE',
    N'Activa_Etiquetada_RE',
    N'Offline_Etiquetada_RE'
)
ORDER BY ExecutedAt, DatabaseName, LogID;
GO
