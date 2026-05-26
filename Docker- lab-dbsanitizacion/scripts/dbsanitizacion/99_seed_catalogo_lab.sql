SET NOCOUNT ON;
SET XACT_ABORT ON;

USE [dbdba];
GO

PRINT '============================================================';
PRINT 'SEED CATALOGO LAB - dbo.servidores / dbo.instancias';
PRINT '============================================================';

IF OBJECT_ID(N'dbo.servidores', N'U') IS NULL
    THROW 51000, 'No existe dbo.servidores. Ejecute primero 05_Caducidad_Tablas.sql.', 1;

IF OBJECT_ID(N'dbo.instancias', N'U') IS NULL
    THROW 51001, 'No existe dbo.instancias. Ejecute primero 05_Caducidad_Tablas.sql.', 1;

MERGE dbo.servidores AS tgt
USING
(
    SELECT
        CAST(N'localhost' AS varchar(20))  AS DireccionIP,
        CAST(N'DOCKERLAB' AS varchar(20))  AS Hostname,
        CAST(N'LAB' AS varchar(20))        AS Ambiente,
        CAST(N'Docker SQL Server Linux' AS varchar(100)) AS Version_SO,
        CAST(GETDATE() AS date)            AS Fecha_actualiza,
        CAST(1 AS int)                     AS estado
) AS src
ON tgt.DireccionIP = src.DireccionIP
WHEN MATCHED THEN
    UPDATE SET
        Hostname = src.Hostname,
        Ambiente = src.Ambiente,
        Version_SO = src.Version_SO,
        Fecha_actualiza = src.Fecha_actualiza,
        estado = src.estado
WHEN NOT MATCHED THEN
    INSERT (DireccionIP, Hostname, Ambiente, Version_SO, Fecha_actualiza, estado)
    VALUES (src.DireccionIP, src.Hostname, src.Ambiente, src.Version_SO, src.Fecha_actualiza, src.estado);

MERGE dbo.instancias AS tgt
USING
(
    SELECT *
    FROM (VALUES
        (CAST(N'localhost' AS varchar(20)), CAST(N'localhost,56964' AS varchar(200)), CAST(N'56964' AS varchar(20)), CAST(N'SQL Server 2022 Developer' AS varchar(100)), CAST(N'1' AS varchar(2)), CAST(N'LAB 1 - instancia destino Docker' AS varchar(200)), CAST(N'N/A' AS varchar(50)), CAST(N'SQLSERVER_LAB_1' AS varchar(250)), CAST(N'DBA' AS varchar(250)), CAST(N'Equipo DBA' AS varchar(250)), CAST(GETDATE() AS date), CAST(N'Linux container' AS varchar(250)), CAST(N'DEV' AS varchar(20))),
        (CAST(N'localhost' AS varchar(20)), CAST(N'localhost,43123' AS varchar(200)), CAST(N'43123' AS varchar(20)), CAST(N'SQL Server 2022 Developer' AS varchar(100)), CAST(N'1' AS varchar(2)), CAST(N'LAB 2 - instancia destino Docker' AS varchar(200)), CAST(N'N/A' AS varchar(50)), CAST(N'SQLSERVER_LAB_2' AS varchar(250)), CAST(N'DBA' AS varchar(250)), CAST(N'Equipo DBA' AS varchar(250)), CAST(GETDATE() AS date), CAST(N'Linux container' AS varchar(250)), CAST(N'QA' AS varchar(20))),
        (CAST(N'localhost' AS varchar(20)), CAST(N'localhost,52789' AS varchar(200)), CAST(N'52789' AS varchar(20)), CAST(N'SQL Server 2022 Developer' AS varchar(100)), CAST(N'1' AS varchar(2)), CAST(N'LAB 3 - instancia destino Docker' AS varchar(200)), CAST(N'N/A' AS varchar(50)), CAST(N'SQLSERVER_LAB_3' AS varchar(250)), CAST(N'DBA' AS varchar(250)), CAST(N'Equipo DBA' AS varchar(250)), CAST(GETDATE() AS date), CAST(N'Linux container' AS varchar(250)), CAST(N'PROVEEDORES' AS varchar(20)))
    ) AS v
    (
        IP_server,
        SERVER_TO_PROD,
        Puerto,
        Version_sql,
        Estado,
        Obs,
        CertificadoNoProd,
        instancia_name,
        CELULA,
        RESPONSABLE,
        fecha_change,
        Sistema_operativo,
        Ambiente
    )
) AS src
ON tgt.IP_server = src.IP_server
AND ISNULL(tgt.Puerto, N'') = ISNULL(src.Puerto, N'')
WHEN MATCHED THEN
    UPDATE SET
        SERVER_TO_PROD = src.SERVER_TO_PROD,
        Version_sql = src.Version_sql,
        Estado = src.Estado,
        Obs = src.Obs,
        CertificadoNoProd = src.CertificadoNoProd,
        instancia_name = src.instancia_name,
        CELULA = src.CELULA,
        RESPONSABLE = src.RESPONSABLE,
        fecha_change = src.fecha_change,
        Sistema_operativo = src.Sistema_operativo,
        Ambiente = src.Ambiente
WHEN NOT MATCHED THEN
    INSERT
    (
        IP_server,
        SERVER_TO_PROD,
        Puerto,
        Version_sql,
        Estado,
        Obs,
        CertificadoNoProd,
        instancia_name,
        CELULA,
        RESPONSABLE,
        fecha_change,
        Sistema_operativo,
        Ambiente
    )
    VALUES
    (
        src.IP_server,
        src.SERVER_TO_PROD,
        src.Puerto,
        src.Version_sql,
        src.Estado,
        src.Obs,
        src.CertificadoNoProd,
        src.instancia_name,
        src.CELULA,
        src.RESPONSABLE,
        src.fecha_change,
        src.Sistema_operativo,
        src.Ambiente
    );

PRINT '[OK] Catalogo dbo.servidores / dbo.instancias poblado para el laboratorio.';

PRINT '--- dbo.servidores ---';
SELECT DireccionIP, Hostname, Ambiente, Version_SO, Fecha_actualiza, estado
FROM dbo.servidores
ORDER BY DireccionIP;

PRINT '--- dbo.instancias ---';
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
GO
