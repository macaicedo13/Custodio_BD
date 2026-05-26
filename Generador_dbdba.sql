/* =============================================================================
  Script        : 05_Caducidad_Tablas.sql
  Servidor      : DBCUSTODIO

  Objetos desplegados (en orden de dependencias) :
    00. CREATE DATABASE dbdba
    01. Logins SQL Server: sa_dbdba, svc_caducidad
    02. Usuarios en dbdba: sa_dbdba, svc_caducidad
    03. CREATE TABLE dbo.servidores
    04. CREATE TABLE dbo.instancias  + FK + columna Ambiente
    05. Permisos sobre dbo.servidores / dbo.instancias
    06. CREATE SCHEMA noprod
    07. CREATE TABLE noprod.LOG_ETIQUETADO_BASES
    08. CREATE TABLE noprod.INVENTARIO_BASES
    09. CREATE TABLE noprod.HISTORIAL_BASES
    10. Permisos sobre tablas noprod para svc_caducidad
    11. CREATE OR ALTER noprod.SP_ETIQUETAR_BASES
    12. CREATE OR ALTER noprod.SP_REMOCION_TDE
    13. Verificacion final

  Autor         : Marco Caicedo
  Fecha         : 2026-05-15
  Version       : 1.9

  Notas :
    - Script idempotente: seguro correr multiples veces.
    - Ejecutar conectado a la instancia DBCUSTODIO con sysadmin.
    - Los passwords de los logins DEBEN cambiarse antes de ejecutar
      en cualquier ambiente. Buscar: <CAMBIAR_PASSWORD>
============================================================================= */

/* =============================================================================
   PASO 00 - CREAR BASE DE DATOS dbdba
============================================================================= */
USE [master];
GO

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'dbdba')
BEGIN
    CREATE DATABASE [dbdba]
        COLLATE SQL_Latin1_General_CP1_CI_AS;
    PRINT '[OK]   Base de datos dbdba creada.';
END
ELSE
    PRINT '[SKIP] Base de datos dbdba ya existe.';
GO

/* =============================================================================
   PASO 01 - LOGINS SQL SERVER
   Crear logins a nivel de instancia.
   IMPORTANTE: cambiar los passwords antes de ejecutar en produccion.
============================================================================= */
USE [master];
GO

-- Login administrador de dbdba
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'sa_dbdba')
BEGIN
    CREATE LOGIN [sa_dbdba]
        WITH PASSWORD    = N'<CAMBIAR_PASSWORD>',  -- cambiar antes de ejecutar
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = ON;
    PRINT '[OK]   Login sa_dbdba creado.';
END
ELSE
    PRINT '[SKIP] Login sa_dbdba ya existe.';
GO

-- Login de servicio para Custodio (permisos minimos)
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'svc_caducidad')
BEGIN
    CREATE LOGIN [svc_caducidad]
        WITH PASSWORD    = N'<CAMBIAR_PASSWORD>',  -- cambiar antes de ejecutar
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = ON;
    PRINT '[OK]   Login svc_caducidad creado.';
END
ELSE
    PRINT '[SKIP] Login svc_caducidad ya existe.';
GO

/* =============================================================================
   PASO 02 - USUARIOS EN dbdba
============================================================================= */
USE [dbdba];
GO

-- Usuario administrador
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'sa_dbdba')
BEGIN
    CREATE USER [sa_dbdba] FOR LOGIN [sa_dbdba];
    ALTER ROLE [db_owner] ADD MEMBER [sa_dbdba];
    PRINT '[OK]   Usuario sa_dbdba creado y agregado a db_owner.';
END
ELSE
    PRINT '[SKIP] Usuario sa_dbdba ya existe.';
GO

-- Usuario de servicio Custodio
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'svc_caducidad')
BEGIN
    CREATE USER [svc_caducidad] FOR LOGIN [svc_caducidad];
    PRINT '[OK]   Usuario svc_caducidad creado.';
END
ELSE
    PRINT '[SKIP] Usuario svc_caducidad ya existe.';
GO

/* =============================================================================
   PASO 03 - TABLA dbo.servidores
   Catalogo de servidores fisicos. PK es DireccionIP.
   Referenciada por dbo.instancias (FK fk_server).
============================================================================= */
USE [dbdba];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = 'servidores' AND schema_id = SCHEMA_ID('dbo')
)
BEGIN
    CREATE TABLE [dbo].[servidores]
    (
        [DireccionIP]     VARCHAR(20)  NOT NULL,
        [Hostname]        VARCHAR(20)  NULL,
        [Ambiente]        VARCHAR(20)  NULL,
        [Version_SO]      VARCHAR(100) NULL,
        [Fecha_actualiza] DATE         NULL,
        [estado]          INT          NULL,

        CONSTRAINT PK_servidores PRIMARY KEY CLUSTERED ([DireccionIP] ASC)
    );

    PRINT '[OK]   Tabla dbo.servidores creada.';
END
ELSE
    PRINT '[SKIP] Tabla dbo.servidores ya existe.';
GO

/* =============================================================================
   PASO 04 - TABLA dbo.instancias
   Catalogo de instancias SQL Server no productivas.
   Referencia a dbo.servidores por IP.
   Custodio procesa instancias donde Estado = 1 AND Ambiente IS NOT NULL.
============================================================================= */
USE [dbdba];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = 'instancias' AND schema_id = SCHEMA_ID('dbo')
)
BEGIN
    CREATE TABLE [dbo].[instancias]
    (
        [ID_instancia]      INT IDENTITY(1,1) NOT NULL,
        [IP_server]         VARCHAR(20)       NOT NULL,
        [SERVER_TO_PROD]    VARCHAR(200)      NULL,
        [Puerto]            VARCHAR(20)       NULL,
        [Version_sql]       VARCHAR(100)      NULL,
        [Estado]            VARCHAR(2)        NULL,      -- '1' = activa | '0' = inactiva
        [Obs]               VARCHAR(200)      NULL,
        [CertificadoNoProd] VARCHAR(50)       NULL,
        [instancia_name]    VARCHAR(250)      NULL,
        [CELULA]            VARCHAR(250)      NULL,
        [RESPONSABLE]       VARCHAR(250)      NULL,
        [fecha_change]      DATE              NULL,
        [Sistema_operativo] VARCHAR(250)      NULL,
        [Ambiente]          VARCHAR(20)       NULL,      -- 'DEV' | 'QA' | 'PROVEEDORES'
                                                         -- requerido para que Custodio procese la instancia

        CONSTRAINT PK_instancias PRIMARY KEY CLUSTERED ([ID_instancia] ASC),

        CONSTRAINT UQ_instancias UNIQUE NONCLUSTERED ([IP_server] ASC, [Puerto] ASC),

        CONSTRAINT fk_server FOREIGN KEY ([IP_server])
            REFERENCES [dbo].[servidores] ([DireccionIP])
    );

    PRINT '[OK]   Tabla dbo.instancias creada.';
    PRINT '       Recuerde poblar Ambiente despues de insertar registros:';
    PRINT '       UPDATE dbo.instancias SET Ambiente = ''DEV''         WHERE <condicion>';
    PRINT '       UPDATE dbo.instancias SET Ambiente = ''QA''          WHERE <condicion>';
    PRINT '       UPDATE dbo.instancias SET Ambiente = ''PROVEEDORES'' WHERE <condicion>';
END
ELSE
BEGIN
    PRINT '[SKIP] Tabla dbo.instancias ya existe.';

    -- Agregar columna Ambiente si no existe (migracion desde version anterior)
    IF NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.instancias') AND name = 'Ambiente'
    )
    BEGIN
        ALTER TABLE dbo.instancias ADD Ambiente VARCHAR(20) NULL;
        PRINT '[OK]   Columna Ambiente agregada a dbo.instancias.';
    END
    ELSE
        PRINT '[SKIP] Columna Ambiente ya existe en dbo.instancias.';
END
GO

/* =============================================================================
   PASO 05 - PERMISOS SOBRE TABLAS BASE PARA svc_caducidad
   Solo lectura sobre servidores e instancias.
============================================================================= */
USE [dbdba];
GO

GRANT SELECT ON dbo.servidores TO [svc_caducidad];
GRANT SELECT ON dbo.instancias TO [svc_caducidad];
PRINT '[OK]   Permisos SELECT sobre dbo.servidores y dbo.instancias otorgados a svc_caducidad.';
GO

/* =============================================================================
   PASO 06 - ESQUEMA noprod
============================================================================= */
USE [dbdba];
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'noprod')
BEGIN
    EXEC('CREATE SCHEMA noprod');
    PRINT '[OK]   Esquema noprod creado.';
END
ELSE
    PRINT '[SKIP] Esquema noprod ya existe.';
GO

/* =============================================================================
   PASO 07 - TABLA noprod.LOG_ETIQUETADO_BASES
   Auditoria del proceso de etiquetado en sanitizacion.
   Escrita por SP_ETIQUETAR_BASES. Una fila por propiedad por BD por ejecucion.
============================================================================= */
USE [dbdba];
GO

-- Renombrar nombre anterior si existe
IF EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = N'LOG_ETIQUETADO_BD' AND schema_id = SCHEMA_ID('noprod')
)
BEGIN
    EXEC sp_rename 'noprod.LOG_ETIQUETADO_BD', 'LOG_ETIQUETADO_BASES';
    PRINT '[OK]   noprod.LOG_ETIQUETADO_BD renombrada a noprod.LOG_ETIQUETADO_BASES.';
END

IF NOT EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = N'LOG_ETIQUETADO_BASES' AND schema_id = SCHEMA_ID('noprod')
)
BEGIN
    CREATE TABLE noprod.LOG_ETIQUETADO_BASES
    (
        LogID            BIGINT IDENTITY(1,1) NOT NULL
                             CONSTRAINT PK_LOG_ETIQUETADO_BASES PRIMARY KEY,
        ExecutionID      UNIQUEIDENTIFIER NOT NULL,
        ExecutedAt       DATETIME2(0)     NOT NULL
                             CONSTRAINT DF_LOG_ETIQUETADO_BASES_ExecutedAt
                             DEFAULT (SYSDATETIME()),
        ExecutedBy       SYSNAME          NOT NULL
                             CONSTRAINT DF_LOG_ETIQUETADO_BASES_ExecutedBy
                             DEFAULT (SUSER_SNAME()),
        DatabaseName     SYSNAME          NOT NULL,
        PropertyName     NVARCHAR(128)    NULL,
        PropertyValue    NVARCHAR(500)    NULL,
        Action           VARCHAR(20)      NOT NULL,   -- ADD / UPDATE / DROP / SKIPPED / ERROR / DEBUG
        Status           VARCHAR(10)      NOT NULL,   -- OK / ERROR
        Message          NVARCHAR(2000)   NULL,
        Caso             NVARCHAR(200)    NULL,
        DBA              NVARCHAR(200)    NULL,
        RazonCodigo      VARCHAR(10)      NULL,       -- RSE / RE
        Razon            NVARCHAR(500)    NULL,
        Responsable      NVARCHAR(500)    NULL,
        FechaExpiracion  DATE             NULL
    );

    CREATE INDEX IX_LOG_ETIQUETADO_BASES_DatabaseName
        ON noprod.LOG_ETIQUETADO_BASES (DatabaseName, ExecutedAt DESC);
    CREATE INDEX IX_LOG_ETIQUETADO_BASES_Caso
        ON noprod.LOG_ETIQUETADO_BASES (Caso);
    CREATE INDEX IX_LOG_ETIQUETADO_BASES_RazonCodigo
        ON noprod.LOG_ETIQUETADO_BASES (RazonCodigo);

    PRINT '[OK]   Tabla noprod.LOG_ETIQUETADO_BASES creada.';
END
ELSE
    PRINT '[SKIP] Tabla noprod.LOG_ETIQUETADO_BASES ya existe.';
GO

/* =============================================================================
   PASO 08 - TABLA noprod.INVENTARIO_BASES
   Catalogo central. Una fila por BD por instancia. Estado siempre actual.
============================================================================= */
USE [dbdba];
GO

-- Renombrar nombre anterior si existe
IF EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = N'BD_INVENTARIO' AND schema_id = SCHEMA_ID('noprod')
)
BEGIN
    EXEC sp_rename 'noprod.BD_INVENTARIO', 'INVENTARIO_BASES';
    PRINT '[OK]   noprod.BD_INVENTARIO renombrada a noprod.INVENTARIO_BASES.';
END

IF NOT EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = N'INVENTARIO_BASES' AND schema_id = SCHEMA_ID('noprod')
)
BEGIN
    CREATE TABLE noprod.INVENTARIO_BASES
    (
        /* ---- Identificacion ---- */
        ID                  BIGINT IDENTITY(1,1) NOT NULL
                                CONSTRAINT PK_INVENTARIO_BASES PRIMARY KEY,
        ID_Instancia        INT           NOT NULL,
        Ambiente            VARCHAR(20)   NOT NULL,  -- duplicado de instancias.Ambiente
                                                     -- sincronizado por Python en cada UPSERT
        DatabaseName        SYSNAME       NOT NULL,

        /* ---- Extended properties leidas desde la BD destino ---- */
        Caso                NVARCHAR(50)  NULL,
        DBA                 NVARCHAR(200) NULL,
        RazonCodigo         VARCHAR(10)   NULL,      -- RSE / RE / NULL
        Responsable         NVARCHAR(500) NULL,
        FechaExpira         DATE          NULL,

        /* ---- Estado del ciclo de vida ---- */
        Estado              VARCHAR(20)   NOT NULL,
        /*
          ACTIVA               RSE con fecha vigente
          PRORROGADA           RSE con al menos una prorroga aplicada
          CADUCADA             Puesta OFFLINE por Custodio al vencer
          RE_CONTROLADA        Enmascarada, no caduca
          SIN_ETIQUETAR        Sin extended properties (alerta)
          RSE_SIN_FECHA        RSE sin fecha de expiracion (alerta)
          OFFLINE_DESCONOCIDA  OFFLINE por razon desconocida (no fue Custodio)
          ELIMINADA            Ya no existe en el servidor destino
        */

        EstadoMotivo        VARCHAR(30)   NULL,
        /*
          BD_NUEVA             Primera vez detectada
          PRORROGA_APLICADA    Ultima accion fue prorroga
          VENCIMIENTO          Paso a CADUCADA por fecha
          ETIQUETADO_FALTANTE  Para SIN_ETIQUETAR
          FECHA_FALTANTE       Para RSE_SIN_FECHA
          BD_OFFLINE           Para OFFLINE_DESCONOCIDA
          BD_ELIMINADA         Para ELIMINADA
        */

        /* ---- Informacion de restauracion ---- */
        FechaRestore        DATETIME2(0)  NULL,
        UsuarioRestore      NVARCHAR(200) NULL,

        /* ---- Control interno ---- */
        UltimoCheck         DATETIME2(0)  NOT NULL
                                CONSTRAINT DF_INVENTARIO_BASES_UltimoCheck
                                DEFAULT (SYSDATETIME()),
        FechaCambioEstado   DATETIME2(0)  NULL,

        /* ---- Restricciones ---- */
        CONSTRAINT FK_INVENTARIO_BASES_Instancia
            FOREIGN KEY (ID_Instancia)
            REFERENCES dbo.instancias (ID_instancia),

        CONSTRAINT UQ_INVENTARIO_BASES
            UNIQUE (ID_Instancia, DatabaseName),

        CONSTRAINT CK_INVENTARIO_BASES_Estado
            CHECK (Estado IN (
                'ACTIVA', 'PRORROGADA', 'CADUCADA',
                'RE_CONTROLADA', 'SIN_ETIQUETAR', 'RSE_SIN_FECHA',
                'OFFLINE_DESCONOCIDA', 'ELIMINADA'
            )),

        CONSTRAINT CK_INVENTARIO_BASES_RazonCodigo
            CHECK (RazonCodigo IN ('RSE', 'RE') OR RazonCodigo IS NULL),

        CONSTRAINT CK_INVENTARIO_BASES_Ambiente
            CHECK (Ambiente IN ('DEV', 'QA', 'PROVEEDORES'))
    );

    CREATE INDEX IX_INVENTARIO_BASES_Estado_Fecha
        ON noprod.INVENTARIO_BASES (Estado, FechaExpira)
        INCLUDE (ID_Instancia, Ambiente, DatabaseName, Caso, Responsable);
    CREATE INDEX IX_INVENTARIO_BASES_Ambiente_Estado
        ON noprod.INVENTARIO_BASES (Ambiente, Estado)
        INCLUDE (DatabaseName, FechaExpira, Caso);
    CREATE INDEX IX_INVENTARIO_BASES_Caso
        ON noprod.INVENTARIO_BASES (Caso)
        WHERE Caso IS NOT NULL;

    PRINT '[OK]   Tabla noprod.INVENTARIO_BASES creada.';
END
ELSE
BEGIN
    PRINT '[SKIP] Tabla noprod.INVENTARIO_BASES ya existe.';

    -- Actualizar CHECK constraint si no incluye los estados nuevos
    DECLARE @def NVARCHAR(MAX);
    SELECT @def = definition
    FROM sys.check_constraints
    WHERE name = 'CK_INVENTARIO_BASES_Estado'
      AND parent_object_id = OBJECT_ID('noprod.INVENTARIO_BASES');

    IF @def IS NOT NULL
       AND (@def NOT LIKE '%OFFLINE_DESCONOCIDA%' OR @def NOT LIKE '%ELIMINADA%')
    BEGIN
        ALTER TABLE noprod.INVENTARIO_BASES DROP CONSTRAINT CK_INVENTARIO_BASES_Estado;
        ALTER TABLE noprod.INVENTARIO_BASES ADD CONSTRAINT CK_INVENTARIO_BASES_Estado
            CHECK (Estado IN (
                'ACTIVA', 'PRORROGADA', 'CADUCADA',
                'RE_CONTROLADA', 'SIN_ETIQUETAR', 'RSE_SIN_FECHA',
                'OFFLINE_DESCONOCIDA', 'ELIMINADA'
            ));
        PRINT '[OK]   CHECK constraint CK_INVENTARIO_BASES_Estado actualizado.';
    END
    ELSE IF @def IS NOT NULL
        PRINT '[SKIP] CHECK constraint ya incluye todos los estados.';
END
GO

/* =============================================================================
   PASO 09 - TABLA noprod.HISTORIAL_BASES
   Historial de eventos por BD. No se elimina: es la memoria historica.
============================================================================= */
USE [dbdba];
GO

-- Renombrar nombre anterior si existe
IF EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = N'HISTORIAL_BD' AND schema_id = SCHEMA_ID('noprod')
)
BEGIN
    EXEC sp_rename 'noprod.HISTORIAL_BD', 'HISTORIAL_BASES';
    PRINT '[OK]   noprod.HISTORIAL_BD renombrada a noprod.HISTORIAL_BASES.';
END

IF NOT EXISTS (
    SELECT 1 FROM sys.tables
    WHERE name = N'HISTORIAL_BASES' AND schema_id = SCHEMA_ID('noprod')
)
BEGIN
    CREATE TABLE noprod.HISTORIAL_BASES
    (
        ID              BIGINT IDENTITY(1,1) NOT NULL
                            CONSTRAINT PK_HISTORIAL_BASES PRIMARY KEY,
        FechaEvento     DATETIME2(0)    NOT NULL
                            CONSTRAINT DF_HISTORIAL_BASES_FechaEvento
                            DEFAULT (SYSDATETIME()),
        EjecutadoPor    NVARCHAR(200)   NOT NULL,
        ID_Instancia    INT             NOT NULL,
        DatabaseName    SYSNAME         NULL,
        TipoEvento      VARCHAR(30)     NOT NULL,
        /*
          BD_DESCUBIERTA          Primera vez detectada
          ETIQUETAS_ACTUALIZADAS  Cambio en estado, caso o fecha
          CADUCAMIENTO_APLICADO   BD puesta OFFLINE por vencimiento
          CADUCAMIENTO_SIMULADO   Dry-run: hubiera sido caducada
          PRORROGA_REGISTRADA     DBA registro prorroga con prorrogar.py
          REACTIVACION            BD traida de OFFLINE a ONLINE
          BD_DESAPARECIDA         Ya no existe en el servidor
          ERROR_CONEXION          Fallo conexion a la instancia
          ERROR_OPERACION         Fallo una operacion especifica
        */
        Detalle         NVARCHAR(MAX)   NULL,        -- JSON con contexto del evento
        Status          VARCHAR(10)     NOT NULL,    -- OK / ERROR

        CONSTRAINT FK_HISTORIAL_BASES_Instancia
            FOREIGN KEY (ID_Instancia)
            REFERENCES dbo.instancias (ID_instancia),

        CONSTRAINT CK_HISTORIAL_BASES_TipoEvento
            CHECK (TipoEvento IN (
                'BD_DESCUBIERTA',        'ETIQUETAS_ACTUALIZADAS',
                'CADUCAMIENTO_APLICADO', 'CADUCAMIENTO_SIMULADO',
                'PRORROGA_REGISTRADA',   'REACTIVACION',
                'BD_DESAPARECIDA',       'ERROR_CONEXION',
                'ERROR_OPERACION'
            )),

        CONSTRAINT CK_HISTORIAL_BASES_Status
            CHECK (Status IN ('OK', 'ERROR'))
    );

    CREATE INDEX IX_HISTORIAL_BASES_BD
        ON noprod.HISTORIAL_BASES (ID_Instancia, DatabaseName, FechaEvento DESC)
        WHERE DatabaseName IS NOT NULL;
    CREATE INDEX IX_HISTORIAL_BASES_Errores
        ON noprod.HISTORIAL_BASES (TipoEvento, FechaEvento DESC)
        WHERE Status = 'ERROR';
    CREATE INDEX IX_HISTORIAL_BASES_Fecha
        ON noprod.HISTORIAL_BASES (FechaEvento DESC)
        INCLUDE (ID_Instancia, DatabaseName, TipoEvento, Status);

    PRINT '[OK]   Tabla noprod.HISTORIAL_BASES creada.';
END
ELSE
    PRINT '[SKIP] Tabla noprod.HISTORIAL_BASES ya existe.';
GO

/* =============================================================================
   PASO 10 - PERMISOS noprod PARA svc_caducidad
============================================================================= */
USE [dbdba];
GO

GRANT SELECT, INSERT, UPDATE ON noprod.INVENTARIO_BASES    TO [svc_caducidad];
GRANT SELECT, INSERT          ON noprod.HISTORIAL_BASES    TO [svc_caducidad];
GRANT SELECT                  ON noprod.LOG_ETIQUETADO_BASES TO [svc_caducidad];
GRANT EXECUTE                 ON noprod.SP_ETIQUETAR_BASES TO [svc_caducidad];

PRINT '[OK]   Permisos noprod otorgados a svc_caducidad.';
GO

/* =============================================================================
   PASO 11 - SP noprod.SP_ETIQUETAR_BASES
============================================================================= */
USE [dbdba];
GO

CREATE OR ALTER PROCEDURE noprod.SP_ETIQUETAR_BASES
    @DatabaseList   NVARCHAR(MAX),
    @Caso           NVARCHAR(200),
    @DBA            NVARCHAR(200),
    @Razon          VARCHAR(10),            -- 'RSE' | 'RE'
    @Responsable    NVARCHAR(500),
    @FechaExpira    DATE          = NULL,
    @Debug          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

/* -----------------------------------------------------------------------------
  Proposito :
    Aplica extended properties estandarizadas en BDs de sanitizacion.
    RSE = Restaurar Sin Enmascarar (requiere FechaExpira)
    RE  = Restaurar Enmascarado    (sin FechaExpira, elimina la existente)

  Historial :
    1.0  2026-05-07  Marco Caicedo  Version inicial.
    1.1  2026-05-07  Marco Caicedo  Migracion a esquema noprod.
----------------------------------------------------------------------------- */

    IF NULLIF(LTRIM(RTRIM(@DatabaseList)), N'') IS NULL
    BEGIN RAISERROR('@DatabaseList no puede estar vacio.', 16, 1); RETURN; END;

    SET @Razon = UPPER(LTRIM(RTRIM(@Razon)));

    IF @Razon NOT IN ('RSE', 'RE')
    BEGIN RAISERROR('@Razon invalida. Use RSE o RE.', 16, 1); RETURN; END;

    IF @Razon = 'RSE' AND @FechaExpira IS NULL
    BEGIN RAISERROR('Para RSE la @FechaExpira es obligatoria.', 16, 1); RETURN; END;

    IF @Razon = 'RE' AND @FechaExpira IS NOT NULL
    BEGIN RAISERROR('Para RE no debe enviarse @FechaExpira.', 16, 1); RETURN; END;

    IF @Razon = 'RSE' AND @FechaExpira < CAST(GETDATE() AS DATE)
    BEGIN RAISERROR('@FechaExpira no puede ser anterior a hoy.', 16, 1); RETURN; END;

    DECLARE @RazonTexto NVARCHAR(500) =
        CASE @Razon WHEN 'RSE' THEN N'Restaurar Sin Enmascarar'
                    WHEN 'RE'  THEN N'Restaurar Enmascarado' END;

    DECLARE @ExecutionID    UNIQUEIDENTIFIER = NEWID();
    DECLARE @FechaExpiraTxt NVARCHAR(10) =
        CASE WHEN @FechaExpira IS NULL THEN NULL
             ELSE CONVERT(NVARCHAR(10), @FechaExpira, 23) END;

    DECLARE @Props TABLE (RowNum INT IDENTITY(1,1), PropertyName NVARCHAR(128) NOT NULL, PropertyValue NVARCHAR(500) NOT NULL);
    INSERT INTO @Props VALUES (N'Caso', @Caso), (N'DBA', @DBA), (N'Razon', @RazonTexto), (N'Responsable', @Responsable);
    IF @Razon = 'RSE' INSERT INTO @Props VALUES (N'Fecha_Expiracion', @FechaExpiraTxt);

    DECLARE @Bases TABLE (DatabaseName SYSNAME PRIMARY KEY);
    INSERT INTO @Bases SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatabaseList, N',')
    WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;

    DECLARE @DatabaseName SYSNAME, @PropertyName NVARCHAR(128), @PropertyValue NVARCHAR(500);
    DECLARE @SQL NVARCHAR(MAX), @Action VARCHAR(20), @DropAction VARCHAR(20);
    DECLARE @PropID INT, @MaxProp INT = (SELECT COUNT(*) FROM @Props);

    DECLARE curBases CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM @Bases ORDER BY DatabaseName;
    OPEN curBases;
    FETCH NEXT FROM curBases INTO @DatabaseName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName)
        BEGIN
            INSERT INTO noprod.LOG_ETIQUETADO_BASES (ExecutionID, DatabaseName, Action, Status, Message, Caso, DBA, RazonCodigo, Razon, Responsable, FechaExpiracion)
            VALUES (@ExecutionID, @DatabaseName, 'SKIPPED', 'ERROR', 'La base de datos no existe.', @Caso, @DBA, @Razon, @RazonTexto, @Responsable, @FechaExpira);
            FETCH NEXT FROM curBases INTO @DatabaseName; CONTINUE;
        END;

        IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName AND state_desc <> 'ONLINE')
        BEGIN
            INSERT INTO noprod.LOG_ETIQUETADO_BASES (ExecutionID, DatabaseName, Action, Status, Message, Caso, DBA, RazonCodigo, Razon, Responsable, FechaExpiracion)
            SELECT @ExecutionID, @DatabaseName, 'SKIPPED', 'ERROR', 'BD no esta ONLINE. Estado: ' + state_desc, @Caso, @DBA, @Razon, @RazonTexto, @Responsable, @FechaExpira
            FROM sys.databases WHERE name = @DatabaseName;
            FETCH NEXT FROM curBases INTO @DatabaseName; CONTINUE;
        END;

        IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName AND is_read_only = 1)
        BEGIN
            INSERT INTO noprod.LOG_ETIQUETADO_BASES (ExecutionID, DatabaseName, Action, Status, Message, Caso, DBA, RazonCodigo, Razon, Responsable, FechaExpiracion)
            VALUES (@ExecutionID, @DatabaseName, 'SKIPPED', 'ERROR', 'BD esta en READ_ONLY.', @Caso, @DBA, @Razon, @RazonTexto, @Responsable, @FechaExpira);
            FETCH NEXT FROM curBases INTO @DatabaseName; CONTINUE;
        END;

        SET @PropID = 1;
        WHILE @PropID <= @MaxProp
        BEGIN
            SELECT @PropertyName = PropertyName, @PropertyValue = PropertyValue FROM @Props WHERE RowNum = @PropID;
            BEGIN TRY
                SET @SQL = N'USE ' + QUOTENAME(@DatabaseName) + N';
                IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE name = @pName AND class = 0 AND major_id = 0 AND minor_id = 0)
                BEGIN EXEC sys.sp_updateextendedproperty @name = @pName, @value = @pValue; SELECT @pAction = ''UPDATE''; END
                ELSE BEGIN EXEC sys.sp_addextendedproperty @name = @pName, @value = @pValue; SELECT @pAction = ''ADD''; END;';

                IF @Debug = 1 BEGIN PRINT '--- ' + @DatabaseName + ' | ' + @PropertyName + ' = ' + @PropertyValue; SET @Action = 'DEBUG'; END
                ELSE EXEC sys.sp_executesql @SQL, N'@pName NVARCHAR(128), @pValue NVARCHAR(500), @pAction VARCHAR(20) OUTPUT',
                         @pName = @PropertyName, @pValue = @PropertyValue, @pAction = @Action OUTPUT;

                INSERT INTO noprod.LOG_ETIQUETADO_BASES (ExecutionID, DatabaseName, PropertyName, PropertyValue, Action, Status, Message, Caso, DBA, RazonCodigo, Razon, Responsable, FechaExpiracion)
                VALUES (@ExecutionID, @DatabaseName, @PropertyName, @PropertyValue, @Action, 'OK', NULL, @Caso, @DBA, @Razon, @RazonTexto, @Responsable, @FechaExpira);
            END TRY
            BEGIN CATCH
                INSERT INTO noprod.LOG_ETIQUETADO_BASES (ExecutionID, DatabaseName, PropertyName, PropertyValue, Action, Status, Message, Caso, DBA, RazonCodigo, Razon, Responsable, FechaExpiracion)
                VALUES (@ExecutionID, @DatabaseName, @PropertyName, @PropertyValue, 'ERROR', 'ERROR', ERROR_MESSAGE(), @Caso, @DBA, @Razon, @RazonTexto, @Responsable, @FechaExpira);
            END CATCH;
            SET @PropID += 1;
        END;

        IF @Razon = 'RE'
        BEGIN
            BEGIN TRY
                SET @DropAction = NULL;
                SET @SQL = N'USE ' + QUOTENAME(@DatabaseName) + N';
                IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE name = N''Fecha_Expiracion'' AND class = 0 AND major_id = 0 AND minor_id = 0)
                BEGIN EXEC sys.sp_dropextendedproperty @name = N''Fecha_Expiracion''; SELECT @pAction = ''DROP''; END;';
                IF @Debug = 1 BEGIN PRINT '--- ' + @DatabaseName + ' | DROP Fecha_Expiracion'; SET @DropAction = 'DEBUG'; END
                ELSE EXEC sys.sp_executesql @SQL, N'@pAction VARCHAR(20) OUTPUT', @pAction = @DropAction OUTPUT;
                IF @DropAction IS NOT NULL
                    INSERT INTO noprod.LOG_ETIQUETADO_BASES (ExecutionID, DatabaseName, PropertyName, PropertyValue, Action, Status, Message, Caso, DBA, RazonCodigo, Razon, Responsable, FechaExpiracion)
                    VALUES (@ExecutionID, @DatabaseName, N'Fecha_Expiracion', NULL, @DropAction, 'OK', 'Eliminada por cambio a RE.', @Caso, @DBA, @Razon, @RazonTexto, @Responsable, @FechaExpira);
            END TRY
            BEGIN CATCH
                INSERT INTO noprod.LOG_ETIQUETADO_BASES (ExecutionID, DatabaseName, PropertyName, PropertyValue, Action, Status, Message, Caso, DBA, RazonCodigo, Razon, Responsable, FechaExpiracion)
                VALUES (@ExecutionID, @DatabaseName, N'Fecha_Expiracion', NULL, 'ERROR', 'ERROR', ERROR_MESSAGE(), @Caso, @DBA, @Razon, @RazonTexto, @Responsable, @FechaExpira);
            END CATCH;
        END;

        FETCH NEXT FROM curBases INTO @DatabaseName;
    END;

    CLOSE curBases; DEALLOCATE curBases;

    SELECT ExecutionID, ExecutedAt, ExecutedBy, DatabaseName, PropertyName, PropertyValue,
           Action, Status, Message, RazonCodigo, Razon, FechaExpiracion
    FROM noprod.LOG_ETIQUETADO_BASES
    WHERE ExecutionID = @ExecutionID
    ORDER BY DatabaseName, LogID;
END
GO

PRINT '[OK]   SP noprod.SP_ETIQUETAR_BASES creado/actualizado.';
GO

/* =============================================================================
   PASO 12 - SP noprod.SP_REMOCION_TDE
============================================================================= */
USE [dbdba];
GO

CREATE OR ALTER PROCEDURE noprod.SP_REMOCION_TDE
    @Accion VARCHAR(10) = NULL   -- NULL = solo mostrar estado | 'REMOVER' = actuar
AS
BEGIN
    SET NOCOUNT ON;

/* -----------------------------------------------------------------------------
  Proposito :
    Sin parametro: muestra estado TDE de todas las BDs.
    Con @Accion = 'REMOVER': ejecuta la remocion segun el estado actual.

  Estados TDE :
    0 = Sin cifrado
    1 = Cifrado habilitado (tiene DEK)
    2 = En proceso de cifrado
    3 = En proceso de descifrado
    5 = Proteccion habilitada por certificado/clave asimetrica

  Historial :
    1.0  2026-05-07  Marco Caicedo  Version inicial.
    1.1  2026-05-07  Marco Caicedo  Migracion a esquema noprod.
----------------------------------------------------------------------------- */

    IF @Accion IS NULL
    BEGIN
        SELECT
            d.name                          AS DatabaseName,
            d.is_encrypted,
            dek.encryption_state,
            CASE dek.encryption_state
                WHEN 0 THEN 'Sin cifrado'
                WHEN 1 THEN 'Cifrado habilitado (tiene DEK)'
                WHEN 2 THEN 'En proceso de cifrado'
                WHEN 3 THEN 'En proceso de descifrado'
                WHEN 5 THEN 'Protegida por certificado/clave asimetrica'
                ELSE       'Estado desconocido'
            END                             AS EstadoDescripcion,
            dek.encryptor_thumbprint,
            dek.percent_complete
        FROM sys.databases d
        LEFT JOIN sys.dm_database_encryption_keys dek ON d.database_id = dek.database_id
        WHERE d.name NOT IN ('master','tempdb','model','msdb')
        ORDER BY d.name;
        RETURN;
    END;

    IF UPPER(@Accion) <> 'REMOVER'
    BEGIN RAISERROR('Valor invalido. Use NULL (ver estado) o ''REMOVER''.', 16, 1); RETURN; END;

    DECLARE @encryption_state INT;
    SELECT @encryption_state = dek.encryption_state
    FROM sys.databases d
    INNER JOIN sys.dm_database_encryption_keys dek ON d.database_id = dek.database_id
    WHERE d.database_id = DB_ID();

    IF @encryption_state IS NULL
    BEGIN PRINT 'La BD no tiene TDE configurado. No se requiere accion.'; RETURN; END;

    IF @encryption_state = 3
    BEGIN
        PRINT 'BD en proceso de descifrado (estado 3). SET ENCRYPTION OFF ya fue ejecutado.';
        PRINT 'Esperar a que el proceso termine antes de continuar.'; RETURN;
    END;

    IF @encryption_state = 1
    BEGIN
        PRINT 'Aplicando SET ENCRYPTION OFF a [' + DB_NAME() + ']...';
        EXEC('ALTER DATABASE [' + DB_NAME() + '] SET ENCRYPTION OFF');
        PRINT 'SET ENCRYPTION OFF aplicado. El descifrado puede tomar varios minutos.';
        PRINT 'Verificar progreso: EXEC noprod.SP_REMOCION_TDE'; RETURN;
    END;

    IF @encryption_state = 5
    BEGIN
        PRINT 'ADVERTENCIA: Hay procesos activos de cifrado (estado 5).';
        PRINT 'Verificar otros casos en proceso. Si es seguro, ejecutar manualmente:';
        PRINT '  DROP DATABASE ENCRYPTION KEY;'; RETURN;
    END;

    PRINT 'Estado TDE (' + CAST(@encryption_state AS VARCHAR) + ') no requiere accion.';
END
GO

PRINT '[OK]   SP noprod.SP_REMOCION_TDE creado/actualizado.';
GO

/* =============================================================================
   PASO 13 - VERIFICACION FINAL
============================================================================= */
USE [dbdba];
GO

PRINT '';
PRINT '=== Verificacion final ===';
PRINT '';

-- Objetos desplegados
SELECT
    s.name          AS Esquema,
    o.name          AS Objeto,
    o.type_desc     AS Tipo,
    o.create_date   AS Creacion
FROM sys.objects o
INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
WHERE (s.name = 'dbo'    AND o.name IN ('servidores', 'instancias'))
   OR (s.name = 'noprod' AND o.name IN (
       'LOG_ETIQUETADO_BASES', 'INVENTARIO_BASES', 'HISTORIAL_BASES',
       'SP_ETIQUETAR_BASES', 'SP_REMOCION_TDE'
   ))
ORDER BY s.name DESC, o.type_desc, o.name;

PRINT '';

-- Usuarios en dbdba
SELECT name AS Usuario, type_desc AS Tipo, create_date AS Creacion
FROM sys.database_principals
WHERE name IN ('sa_dbdba', 'svc_caducidad');

PRINT '';
PRINT '=== Despliegue CUSTODIO v1.9 completado ===';
PRINT '';
PRINT 'PENDIENTE MANUAL:';
PRINT '  1. Cambiar passwords de sa_dbdba y svc_caducidad (<CAMBIAR_PASSWORD>).';
PRINT '  2. Crear usuario svc_caducidad en cada instancia destino con permisos minimos.';
PRINT '  3. Poblar dbo.servidores e dbo.instancias con los servidores registrados.';
PRINT '  4. Actualizar Ambiente en dbo.instancias (DEV / QA / PROVEEDORES).';
GO
