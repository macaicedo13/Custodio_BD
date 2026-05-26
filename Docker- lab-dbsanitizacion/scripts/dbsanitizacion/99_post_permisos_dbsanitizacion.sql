USE [dbdba];
GO

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'svc_caducidad')
BEGIN
    IF OBJECT_ID(N'noprod.SP_ETIQUETAR_BASES', N'P') IS NOT NULL
        GRANT EXECUTE ON noprod.SP_ETIQUETAR_BASES TO [svc_caducidad];

    IF OBJECT_ID(N'noprod.SP_REMOCION_TDE', N'P') IS NOT NULL
        GRANT EXECUTE ON noprod.SP_REMOCION_TDE TO [svc_caducidad];

    PRINT '[OK] Permisos post despliegue aplicados sobre procedimientos noprod.';
END
ELSE
BEGIN
    RAISERROR('No existe el usuario svc_caducidad en dbdba.', 16, 1);
END
GO


