# Docker Lab — DBCUSTODIO

Entorno de laboratorio local basado en Docker con 4 contenedores SQL Server 2022 Developer Edition.
Diseñado para validar el funcionamiento de **Custodio** — herramienta de gestión y ciclo de vida
de bases de datos en múltiples instancias — sin afectar entornos reales.

---

## Contenedores

| Contenedor | Puerto | Rol |
|---|---|---|
| `DBCUSTODIO` | 55432 | Servidor central — aloja la base `dbdba` con el inventario y el historial |
| `sqlserver_lab_1` | 56964 | Instancia destino — Ambiente DEV |
| `sqlserver_lab_2` | 43123 | Instancia destino — Ambiente QA |
| `sqlserver_lab_3` | 52789 | Instancia destino — Ambiente PROVEEDORES |

---

## Usuarios y credenciales

| Usuario | Contraseña | Alcance |
|---|---|---|
| `sa` | `SqlServer2026!Lab` | Administrador — los 4 contenedores |
| `svc_caducidad` | `SvcCaducidad2026!Lab` | Cuenta de servicio de Custodio — permisos mínimos en instancias destino |
| `dba1` | `dba1` | Sysadmin en las 3 instancias destino |
| `dba2` | `dba2` | Sysadmin en las 3 instancias destino |

### Permisos de svc_caducidad en instancias destino

- `VIEW ANY DATABASE` — lectura de `sys.databases`
- `ALTER ANY DATABASE` — para ejecutar `SET OFFLINE` en bases vencidas
- `SELECT` sobre `msdb.dbo.restorehistory` y `msdb.dbo.backupset`
- Usuario en cada base de datos de prueba — lectura de extended properties

---

## Bases de datos de prueba

Cada base cubre un escenario distinto del ciclo de vida que Custodio monitorea.

| Instancia | Puerto | Ambiente | Base | Estado | Etiqueta | Fecha expira | Estado esperado en Custodio |
|---|---|---|---|---|---|---|---|
| LAB1 | 56964 | DEV | `Activa_Etiquetada_RSE` | ONLINE | RSE | hoy + 15 días | ACTIVA |
| LAB1 | 56964 | DEV | `Offline_SinEtiqueta` | OFFLINE | — | — | OFFLINE_DESCONOCIDA |
| LAB1 | 56964 | DEV | `SinBackup` | ONLINE | — | — | SIN_ETIQUETAR |
| LAB1 | 56964 | DEV | `Activa_Vencida_Ayer` | ONLINE | RSE | ayer | ACTIVA → Custodio aplica CADUCADA |
| LAB1 | 56964 | DEV | `Activa_Vence_Hoy` | ONLINE | RSE | hoy | ACTIVA → Custodio aplica CADUCADA |
| LAB2 | 43123 | QA | `Offline_Etiquetada_RE` | OFFLINE | RE | — | OFFLINE_DESCONOCIDA |
| LAB2 | 43123 | QA | `Activa_SinEtiqueta` | ONLINE | — | — | SIN_ETIQUETAR |
| LAB3 | 52789 | PROVEEDORES | `Activa_Etiquetada_RE` | ONLINE | RE | — | RE_CONTROLADA |
| LAB3 | 52789 | PROVEEDORES | `Offline_Etiquetada_RSE` | OFFLINE | RSE | hoy − 5 días | OFFLINE_DESCONOCIDA → al traer ONLINE → CADUCADA |

---

## Requisitos

- Docker Desktop con soporte para contenedores Linux
- PowerShell 5.1 o superior
- Puertos 55432, 56964, 43123 y 52789 disponibles en el host

---

## Levantar el laboratorio

```powershell
# 1. Levantar los contenedores
docker compose up -d

# 2. Inicializar DBCUSTODIO (schema + datos base)
powershell -ExecutionPolicy Bypass -File .\run_init_dbsanitizacion.ps1

# 3. Crear seeds y restaurar BDs de prueba en las instancias destino
powershell -ExecutionPolicy Bypass -File .\run_seed_all.ps1

```

---

## Ejecutar Custodio contra el lab

Desde la carpeta raíz del proyecto Custodio, activar el entorno de laboratorio
usando `ENV_FILE=.env.lab` antes de ejecutar:

```powershell
$env:ENV_FILE = ".env.lab"; python main.py
```

---

## Reset completo

Elimina los volúmenes y reconstruye el lab desde cero. El script espera a que
los contenedores estén listos antes de ejecutar la inicialización y el seed:

```powershell
powershell -ExecutionPolicy Bypass -File .\reset_lab.ps1
```
