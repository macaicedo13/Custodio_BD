$ErrorActionPreference = "Stop"

$SaPassword = "SqlServer2026!Lab"
$Server = "localhost,55432"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DbSanDir = Join-Path $ScriptDir "scripts\dbsanitizacion"
$PreLogins = Join-Path $DbSanDir "00_precrear_logins_lab.sql"
$OriginalScript = Join-Path $DbSanDir "05_Caducidad_Tablas.sql"
$PostPermisos = Join-Path $DbSanDir "99_post_permisos_dbsanitizacion.sql"
$SeedCatalogoLab = Join-Path $DbSanDir "99_seed_catalogo_lab.sql"
$ValidateScript = Join-Path $DbSanDir "validar_dbsanitizacion.sql"

function Wait-SqlServer {
    param(
        [string]$Server,
        [string]$Password,
        [int]$Retries = 40,
        [int]$Seconds = 5
    )

    for ($i = 1; $i -le $Retries; $i++) {
        Write-Host "Esperando DBCUSTODIO ($Server). Intento $i/$Retries..."
        sqlcmd -S $Server -U sa -P $Password -C -Q "SELECT 1" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "DBCUSTODIO lista."
            return
        }
        Start-Sleep -Seconds $Seconds
    }

    throw "DBCUSTODIO no respondio despues de $($Retries * $Seconds) segundos."
}

Write-Host "============================================================"
Write-Host "Inicializando DBCUSTODIO - $Server"
Write-Host "============================================================"

Wait-SqlServer -Server $Server -Password $SaPassword

Write-Host "Precreando logins de laboratorio para evitar placeholders de password..."
sqlcmd -S $Server -U sa -P $SaPassword -C -b -i $PreLogins

Write-Host "Ejecutando script original 05_Caducidad_Tablas.sql - primera pasada."
Write-Host "Nota: esta pasada puede mostrar un error de GRANT EXECUTE si el SP aun no existe; se corrige con la segunda pasada."
sqlcmd -S $Server -U sa -P $SaPassword -C -i $OriginalScript

Write-Host "Ejecutando script original 05_Caducidad_Tablas.sql - segunda pasada idempotente."
sqlcmd -S $Server -U sa -P $SaPassword -C -b -i $OriginalScript

Write-Host "Aplicando permisos post despliegue."
sqlcmd -S $Server -U sa -P $SaPassword -C -b -i $PostPermisos

Write-Host "Poblando catalogo de servidores e instancias del laboratorio."
sqlcmd -S $Server -U sa -P $SaPassword -C -b -i $SeedCatalogoLab

Write-Host "Validando DBCUSTODIO."
sqlcmd -S $Server -U sa -P $SaPassword -C -b -i $ValidateScript

Write-Host "============================================================"
Write-Host "DBCUSTODIO inicializada correctamente."
Write-Host "============================================================"
Write-Host "Conexion SSMS: localhost,55432"
Write-Host "Logins disponibles:"
Write-Host "  sa             / SqlServer2026!Lab"
Write-Host "  svc_caducidad  / SvcCaducidad2026!Lab"
