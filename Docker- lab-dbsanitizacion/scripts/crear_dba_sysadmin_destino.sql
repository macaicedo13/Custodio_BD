SET NOCOUNT ON;

USE [master];
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'dba1')
BEGIN
    CREATE LOGIN [dba1]
    WITH PASSWORD = N'dba1',
         CHECK_POLICY = OFF,
         CHECK_EXPIRATION = OFF;
    PRINT '[OK] Login dba1 creado.';
END
ELSE
BEGIN
    ALTER LOGIN [dba1] WITH CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [dba1] WITH PASSWORD = N'dba1';
    PRINT '[OK] Login dba1 actualizado.';
END
GO

IF IS_SRVROLEMEMBER(N'sysadmin', N'dba1') <> 1
BEGIN
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [dba1];
    PRINT '[OK] dba1 agregado al rol sysadmin.';
END
ELSE
BEGIN
    PRINT '[SKIP] dba1 ya pertenece al rol sysadmin.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'dba2')
BEGIN
    CREATE LOGIN [dba2]
    WITH PASSWORD = N'dba2',
         CHECK_POLICY = OFF,
         CHECK_EXPIRATION = OFF;
    PRINT '[OK] Login dba2 creado.';
END
ELSE
BEGIN
    ALTER LOGIN [dba2] WITH CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [dba2] WITH PASSWORD = N'dba2';
    PRINT '[OK] Login dba2 actualizado.';
END
GO

IF IS_SRVROLEMEMBER(N'sysadmin', N'dba2') <> 1
BEGIN
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [dba2];
    PRINT '[OK] dba2 agregado al rol sysadmin.';
END
ELSE
BEGIN
    PRINT '[SKIP] dba2 ya pertenece al rol sysadmin.';
END
GO

PRINT '[OK] Usuarios DBA de laboratorio creados/actualizados con rol sysadmin. CHECK_POLICY=OFF para laboratorio.';
GO
