USE [master];
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'svc_caducidad')
BEGIN
    CREATE LOGIN [svc_caducidad]
    WITH PASSWORD = N'SvcCaducidad2026!Lab',
         CHECK_POLICY = OFF,
         CHECK_EXPIRATION = OFF;
    PRINT '[OK] Login svc_caducidad precreado para laboratorio.';
END
ELSE
BEGIN
    ALTER LOGIN [svc_caducidad] WITH CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [svc_caducidad] WITH PASSWORD = N'SvcCaducidad2026!Lab';
    PRINT '[OK] Login svc_caducidad actualizado para laboratorio.';
END
GO
