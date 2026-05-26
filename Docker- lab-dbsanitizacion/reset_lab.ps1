$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Server   = "localhost,55432"
$Password = "SqlServer2026!Lab"
$MaxIntentos = 40

Write-Host "============================================================"
Write-Host "RESET COMPLETO DEL LABORATORIO"
Write-Host "============================================================"

Write-Host "Bajando contenedores y eliminando volumenes..."
docker compose down -v

Write-Host "Levantando contenedores limpios..."
docker compose up -d

Write-Host "Esperando que DBCUSTODIO este lista..."
$listo = $false
for ($i = 1; $i -le $MaxIntentos; $i++) {
    Start-Sleep -Seconds 3
    sqlcmd -S $Server -U sa -P $Password -C -Q "SELECT 1" *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "DBCUSTODIO lista (intento $i)."
        $listo = $true
        break
    }
    Write-Host "Intento $i/$MaxIntentos - aun no responde..."
}

if (-not $listo) {
    Write-Host "ERROR: DBCUSTODIO no respondio despues de $MaxIntentos intentos."
    exit 1
}

Write-Host "Inicializando DBCUSTODIO..."
powershell -ExecutionPolicy Bypass -File "$Root\run_init_DBCUSTODIO.ps1"

Write-Host "Generando seed completo..."
powershell -ExecutionPolicy Bypass -File "$Root\run_seed_all.ps1"

Write-Host "============================================================"
Write-Host "Lab listo."
Write-Host "============================================================"