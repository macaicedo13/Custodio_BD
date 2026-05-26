param(
    [string]$SaPassword = "SqlServer2026!Lab"
)

$ErrorActionPreference = "Stop"

function Invoke-SqlFile {
    param(
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)][string]$User,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][string]$File,
        [string[]]$Variables = @()
    )

    Write-Host "==> Ejecutando $File en $Server con usuario $User" -ForegroundColor Cyan

    $args = @("-S", $Server, "-U", $User, "-P", $Password, "-C", "-b", "-i", $File)
    if ($Variables.Count -gt 0) {
        $args += "-v"
        $args += $Variables
    }

    sqlcmd @args
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CreateSvcScript = Join-Path $Root "scripts\crear_svc_caducidad_destino.sql"
$CreateDbaScript = Join-Path $Root "scripts\crear_dba_sysadmin_destino.sql"
$SeedDBCUSTODIO = Join-Path $Root "scripts\dbsanitizacion\10_seed_origen_etiquetar_backup.sql"
$SeedLabScript = Join-Path $Root "scripts\seed_lab_distribuido.sql"
$ValidateLabScript = Join-Path $Root "scripts\validar_lab.sql"
$ValidateDBCUSTODIO = Join-Path $Root "scripts\dbsanitizacion\validar_dbsanitizacion.sql"

Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "1) Generar BDs origen en DBCUSTODIO, etiquetar con SP y crear backups" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Invoke-SqlFile -Server "localhost,55432" -User "sa" -Password $SaPassword -File $SeedDBCUSTODIO

Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "2) Crear usuarios svc_caducidad, dba1 y dba2 en instancias destino" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
foreach ($port in @(56964,43123,52789)) {
    Invoke-SqlFile -Server "localhost,$port" -User "sa" -Password $SaPassword -File $CreateSvcScript
    Invoke-SqlFile -Server "localhost,$port" -User "sa" -Password $SaPassword -File $CreateDbaScript
}

Write-Host "Aplicando permisos de lectura a los backups..."
docker exec dbcustodio bash -c "chmod 644 /var/opt/mssql/shared/*.bak"
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "3) Restaurar backups en ambientes usando dba1/dba2" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow

$Labs = @(
    @{ LabId = 1; Port = 56964 },
    @{ LabId = 2; Port = 43123 },
    @{ LabId = 3; Port = 52789 }
)

foreach ($lab in $Labs) {
    foreach ($restoreBy in @("dba1", "dba2")) {
        Invoke-SqlFile `
            -Server "localhost,$($lab.Port)" `
            -User $restoreBy `
            -Password $restoreBy `
            -File $SeedLabScript `
            -Variables @("LAB_ID=$($lab.LabId)", "RESTORE_BY=$restoreBy")
    }
}

Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "4) Validar DBCUSTODIO y ambientes" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Invoke-SqlFile -Server "localhost,55432" -User "sa" -Password $SaPassword -File $ValidateDBCUSTODIO

foreach ($lab in $Labs) {
    Invoke-SqlFile `
        -Server "localhost,$($lab.Port)" `
        -User "sa" `
        -Password $SaPassword `
        -File $ValidateLabScript `
        -Variables @("LAB_ID=$($lab.LabId)")
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host "Flujo completo generado: DBCUSTODIO -> backup -> restore en LAB1/LAB2/LAB3." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
