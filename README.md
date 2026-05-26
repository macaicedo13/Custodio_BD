# Custodio

Herramienta de gestión y ciclo de vida de bases de datos SQL Server distribuidas en múltiples instancias.
Custodio sincroniza un inventario centralizado, clasifica cada base según su estado y aplica
automáticamente la baja (`OFFLINE`) a las que han vencido su fecha de autorización.

---

## Cómo funciona

Custodio se ejecuta de forma programada (típicamente nocturna) y sigue dos pasos:

**Paso 1 — Sincronización de inventario**

Para cada instancia activa registrada en el servidor central, Custodio:
- Lee todas las bases de datos presentes en el servidor destino.
- Lee sus *extended properties* para determinar tipo y fecha de autorización.
- Clasifica cada base y registra o actualiza su estado en `noprod.INVENTARIO_BASES`.
- Detecta bases desaparecidas y las marca como `ELIMINADA`.
- Registra cada evento relevante en `noprod.HISTORIAL_BASES`.

**Paso 2 — Aplicación de caducidades**

Custodio consulta todas las bases con estado `ACTIVA` o `PRORROGADA` cuya fecha de expiración
ya venció, ejecuta `ALTER DATABASE SET OFFLINE WITH ROLLBACK IMMEDIATE` en la instancia
correspondiente y actualiza el inventario a `CADUCADA`.

---

## Estados de una base de datos

| Estado | Descripción |
|---|---|
| `ACTIVA` | Autorizada (RSE) con fecha vigente |
| `PRORROGADA` | Autorizada con al menos una extensión aplicada |
| `RE_CONTROLADA` | Enmascarada (RE) — no tiene fecha de vencimiento |
| `SIN_ETIQUETAR` | Sin extended properties — requiere atención |
| `RSE_SIN_FECHA` | RSE sin fecha de expiración registrada — requiere atención |
| `OFFLINE_DESCONOCIDA` | Offline por causa ajena a Custodio |
| `ELIMINADA` | Ya no existe en el servidor destino |
| `CADUCADA` | Puesta offline por Custodio al vencer su autorización |

---

## Extended properties que Custodio lee

Custodio lee estas propiedades extendidas a nivel de base de datos en cada instancia destino:

| Propiedad | Descripción |
|---|---|
| `Caso` | Identificador del caso de autorización |
| `DBA` | DBA responsable |
| `Razon` | `Restaurar Sin Enmascarar` (RSE) o `Restaurar Enmascarado` (RE) |
| `Responsable` | Responsable funcional de la base |
| `Fecha_Expiracion` | Fecha límite de uso (formato `YYYY-MM-DD`) |

---

## Módulos

| Archivo | Rol |
|---|---|
| `main.py` | Orquestador principal — ejecuta el proceso completo |
| `inventario.py` | Sincronización y clasificación de bases por instancia |
| `caducidad.py` | Detección y aplicación de baja a bases vencidas |
| `prorrogar.py` | CLI para extender la autorización de una base |
| `db.py` | Gestión de conexiones ODBC al servidor central e instancias destino |
| `config.py` | Lectura y validación de variables de entorno |
| `logger.py` | Logger con rotación diaria y retención configurable |

---

## Configuración

Copiar `.env.example` a `.env` y completar los valores:

```env
# Servidor central (aloja el inventario)
SAN_HOST=
SAN_PORT=1433
SAN_DATABASE=dbdba
SAN_USER=
SAN_PASSWORD=

# Credencial única para todas las instancias destino
DEST_USER=
DEST_PASSWORD=

# Opcionales
CONN_TIMEOUT=30
LOG_RETENTION_DAYS=90
LOG_DIR=logs
```

Para apuntar a un entorno distinto sin modificar `.env`, usar la variable `ENV_FILE`:

```powershell
$env:ENV_FILE = ".env.lab"; python main.py
```

---

## Ejecución

```powershell
# Crear y activar el entorno virtual
python -m venv venv
venv\Scripts\activate

# Instalar dependencias
pip install -r requirements.txt

# Ejecutar el proceso completo
python main.py

# Extender la autorización de una base manualmente
python prorrogar.py `
    --instancia-id 12 `
    --bd NombreBase `
    --caso-nuevo 99001 `
    --fecha-nueva 2026-12-31 `
    --motivo "Extensión aprobada" `
    --aprobado-por "Nombre Apellido"
```

---

## Ejemplos de uso

### Escenario 1 — Caducamiento automático

Una base con `Fecha_Expiracion` vencida pasa a `OFFLINE` al correr el proceso:

```powershell
python main.py
```

Custodio la detecta en el inventario con estado `ACTIVA` o `PRORROGADA` y fecha vencida,
ejecuta `SET OFFLINE` en la instancia destino y registra el evento `CADUCAMIENTO_APLICADO`.

Verificar en el servidor central:
```sql
SELECT DatabaseName, Estado, FechaExpira, FechaCambioEstado
FROM noprod.INVENTARIO_BASES
WHERE Estado = 'CADUCADA'
ORDER BY FechaCambioEstado DESC;
```

---

### Escenario 2 — Prórroga y reactivación

Ante una base caducada que recibe una nueva autorización, ejecutar `prorrogar.py`
con el nuevo caso y la nueva fecha:

```powershell
python prorrogar.py `
    --instancia-id 3 `
    --bd NombreBase `
    --caso-nuevo 99002 `
    --fecha-nueva 2026-12-31 `
    --motivo "Autorización extendida" `
    --aprobado-por "Nombre Apellido"
```

Custodio trae la base `ONLINE`, actualiza las extended properties en la instancia destino
y registra los eventos `REACTIVACION` y `PRORROGA_REGISTRADA` en el historial.

Verificar que la base quedó `ONLINE` y con el estado actualizado:
```sql
SELECT DatabaseName, Estado, Caso, FechaExpira, FechaCambioEstado
FROM noprod.INVENTARIO_BASES
WHERE DatabaseName = 'NombreBase';

SELECT TipoEvento, FechaEvento, Detalle
FROM noprod.HISTORIAL_BASES
WHERE DatabaseName = 'NombreBase'
ORDER BY FechaEvento DESC;
```

---

### Escenario 3 — Segunda pasada del inventario

Después de la prórroga, correr `main.py` nuevamente para sincronizar el estado:

```powershell
python main.py
```

Custodio lee las extended properties actualizadas, confirma la nueva fecha y
deja la base en estado `PRORROGADA` en el inventario.

---

## Requisitos

- Python 3.11+
- ODBC Driver 17 for SQL Server
- Acceso de red a las instancias SQL Server registradas

---

## Laboratorio local

El directorio `Docker- lab-dbsanitizacion/` contiene un entorno Docker con 4 contenedores
SQL Server 2022 que replica la topología completa (servidor central + 3 instancias destino)
para probar Custodio sin afectar entornos reales. Ver el `README.md` dentro de esa carpeta.
