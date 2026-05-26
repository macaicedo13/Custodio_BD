USE [master];
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'svc_caducidad')
BEGIN
    CREATE LOGIN [svc_caducidad]
    WITH PASSWORD = N'SvcCaducidad2026!Lab',
         CHECK_POLICY = OFF,
         CHECK_EXPIRATION = OFF;
    PRINT '[OK] Login svc_caducidad creado.';
END
ELSE
BEGIN
    ALTER LOGIN [svc_caducidad] WITH CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [svc_caducidad] WITH PASSWORD = N'SvcCaducidad2026!Lab';
    PRINT '[OK] Login svc_caducidad actualizado.';
END
GO

IF IS_SRVROLEMEMBER(N'sysadmin', N'svc_caducidad') <> 1
BEGIN
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [svc_caducidad];
    PRINT '[OK] svc_caducidad agregado a sysadmin.';
END
GO

PRINT '[OK] svc_caducidad listo con sysadmin en instancia destino.';
GO