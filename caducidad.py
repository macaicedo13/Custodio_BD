"""
caducidad.py
------------
Logica para aplicar caducidad a BDs vencidas en instancias destino.

Para cada BD en INVENTARIO_BASES con:
  - Estado IN (ACTIVA, PRORROGADA)
  - FechaExpira <= hoy

Ejecuta:
  ALTER DATABASE [nombre] SET OFFLINE WITH ROLLBACK IMMEDIATE

Actualiza INVENTARIO_BASES: Estado = CADUCADA
Registra evento en HISTORIAL_BASES: CADUCAMIENTO_APLICADO

Modo dry-run:
  Si dry_run=True, NO ejecuta SET OFFLINE ni cambia el inventario.
  Solo deja constancia en el log y registra CADUCAMIENTO_SIMULADO
  en HISTORIAL_BASES con el mismo JSON mas el flag "simulado": true.
"""

import pyodbc
from datetime import date

from db import conectar_sanitizacion, conectar_destino
from inventario import registrar_evento
from logger import get_logger

log = get_logger(__name__)

EJECUTOR = "caducidad.py"


def obtener_bases_por_caducar(san_conn: pyodbc.Connection) -> list[dict]:
    """
    Retorna las BDs activas o prorrogadas con fecha de expiracion vencida.
    """
    sql = """
        SELECT
            inv.ID,
            inv.ID_Instancia,
            inv.Ambiente,
            inv.DatabaseName,
            inv.Caso,
            inv.Responsable,
            inv.FechaExpira,
            i.IP_server,
            i.Puerto,
            i.instancia_name
        FROM noprod.INVENTARIO_BASES inv
        INNER JOIN dbo.instancias i ON inv.ID_Instancia = i.ID_instancia
        WHERE inv.Estado IN ('ACTIVA', 'PRORROGADA')
          AND inv.FechaExpira <= CAST(GETDATE() AS DATE)
          AND i.Estado = 1
        ORDER BY inv.Ambiente, i.instancia_name, inv.DatabaseName
    """
    cursor = san_conn.cursor()
    cursor.execute(sql)
    cols = [col[0] for col in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]


def aplicar_offline(
    san_conn: pyodbc.Connection,
    bd:       dict,
    dry_run:  bool = False,
) -> bool:
    """
    Pone OFFLINE una BD en su instancia destino y actualiza el inventario.

    En modo dry_run, NO ejecuta SET OFFLINE ni cambia el inventario.
    Verifica el estado actual de la BD en destino y registra el evento
    CADUCAMIENTO_SIMULADO en HISTORIAL_BASES.

    Args:
        san_conn: Conexion a sanitizacion.
        bd:       Dict con info de la BD (de obtener_bases_por_caducar).
        dry_run:  Si True, simula sin aplicar cambios destructivos.

    Returns:
        True si se aplico (o se simulo correctamente), False si hubo error.
    """
    nombre   = bd["instancia_name"]
    host     = bd["IP_server"]
    port     = bd["Puerto"]
    db_name  = bd["DatabaseName"]
    hoy      = date.today()
    dias_vencida = (hoy - bd["FechaExpira"]).days
    prefijo  = "[DRY-RUN] " if dry_run else ""

    try:
        with conectar_destino(host, port, nombre) as dest_conn:
            dest_conn.autocommit = True   # DDL requiere autocommit
            cursor = dest_conn.cursor()

            # Verificar que la BD sigue existiendo y ONLINE antes de actuar
            cursor.execute(
                "SELECT state_desc FROM sys.databases WHERE name = ?",
                [db_name]
            )
            row = cursor.fetchone()

            if not row:
                log.warning(f"{prefijo}[{nombre}] [{db_name}] BD no encontrada en el servidor. Omitiendo.")
                return False

            if row.state_desc != "ONLINE":
                log.info(f"{prefijo}[{nombre}] [{db_name}] BD ya no esta ONLINE ({row.state_desc}). Omitiendo.")
                return False

            if dry_run:
                log.info(
                    f"[DRY-RUN] [{nombre}] [{db_name}] Se aplicaria OFFLINE. "
                    f"Vencida hace {dias_vencida} dia(s). Caso {bd.get('Caso')}."
                )
            else:
                sql_offline = f"ALTER DATABASE [{db_name}] SET OFFLINE WITH ROLLBACK IMMEDIATE"
                cursor.execute(sql_offline)
                log.info(f"[{nombre}] [{db_name}] OFFLINE aplicado. Vencida hace {dias_vencida} dia(s).")

        detalle_evento = {
            "caso":            bd.get("Caso"),
            "fechaExpiracion": bd["FechaExpira"].isoformat(),
            "diasVencida":     dias_vencida,
            "responsable":     bd.get("Responsable"),
        }

        if dry_run:
            # No se toca INVENTARIO_BASES; solo se deja la simulacion en HISTORIAL.
            detalle_evento["simulado"] = True
            registrar_evento(
                san_conn      = san_conn,
                id_instancia  = bd["ID_Instancia"],
                database_name = db_name,
                tipo_evento   = "CADUCAMIENTO_SIMULADO",
                detalle       = detalle_evento,
                status        = "OK",
                ejecutado_por = EJECUTOR,
            )
            return True

        _actualizar_estado_caducada(san_conn, bd["ID"])
        registrar_evento(
            san_conn      = san_conn,
            id_instancia  = bd["ID_Instancia"],
            database_name = db_name,
            tipo_evento   = "CADUCAMIENTO_APLICADO",
            detalle       = detalle_evento,
            status        = "OK",
            ejecutado_por = EJECUTOR,
        )
        return True

    except pyodbc.Error as e:
        log.error(f"{prefijo}[{nombre}] [{db_name}] Error al aplicar OFFLINE: {e}")
        registrar_evento(
            san_conn      = san_conn,
            id_instancia  = bd["ID_Instancia"],
            database_name = db_name,
            tipo_evento   = "ERROR_OPERACION",
            detalle       = {
                "operacion": "SET OFFLINE",
                "dryRun":    dry_run,
                "error":     str(e),
            },
            status        = "ERROR",
            ejecutado_por = EJECUTOR,
        )
        return False


def _actualizar_estado_caducada(
    san_conn: pyodbc.Connection,
    inv_id:   int,
) -> None:
    """Actualiza el estado de la BD a CADUCADA en INVENTARIO_BASES."""
    sql = """
        UPDATE noprod.INVENTARIO_BASES
        SET Estado            = 'CADUCADA',
            EstadoMotivo      = 'VENCIMIENTO',
            FechaCambioEstado = SYSDATETIME(),
            UltimoCheck       = SYSDATETIME()
        WHERE ID = ?
    """
    cursor = san_conn.cursor()
    cursor.execute(sql, [inv_id])
    san_conn.commit()


def procesar_caducidades(san_conn: pyodbc.Connection, dry_run: bool = False) -> dict:
    """
    Busca y aplica OFFLINE a todas las BDs vencidas.

    Args:
        san_conn: Conexion a sanitizacion.
        dry_run:  Si True, simula sin aplicar SET OFFLINE.

    Returns:
        dict con resumen: total, aplicadas, errores
    """
    bases = obtener_bases_por_caducar(san_conn)

    resumen = {
        "total":     len(bases),
        "aplicadas": 0,
        "errores":   0,
        "dryRun":    dry_run,
    }

    if not bases:
        log.info("No hay BDs vencidas para caducar.")
        return resumen

    sufijo = " (SIMULACION - no se aplicara OFFLINE)" if dry_run else ""
    log.info(f"{len(bases)} BD(s) vencidas encontradas para caducar.{sufijo}")

    for bd in bases:
        exito = aplicar_offline(san_conn, bd, dry_run=dry_run)
        if exito:
            resumen["aplicadas"] += 1
        else:
            resumen["errores"] += 1

    return resumen
