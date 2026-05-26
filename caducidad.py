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
) -> bool:
    """
    Pone OFFLINE una BD en su instancia destino y actualiza el inventario.

    Args:
        san_conn: Conexion a sanitizacion.
        bd:       Dict con info de la BD (de obtener_bases_por_caducar).

    Returns:
        True si se aplico correctamente, False si hubo error.
    """
    nombre   = bd["instancia_name"]
    host     = bd["IP_server"]
    port     = bd["Puerto"]
    db_name  = bd["DatabaseName"]
    hoy      = date.today()
    dias_vencida = (hoy - bd["FechaExpira"]).days

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
                log.warning(f"[{nombre}] [{db_name}] BD no encontrada en el servidor. Omitiendo.")
                return False

            if row.state_desc != "ONLINE":
                log.info(f"[{nombre}] [{db_name}] BD ya no esta ONLINE ({row.state_desc}). Omitiendo.")
                return False

            # Aplicar OFFLINE
            sql_offline = f"ALTER DATABASE [{db_name}] SET OFFLINE WITH ROLLBACK IMMEDIATE"
            cursor.execute(sql_offline)
            log.info(f"[{nombre}] [{db_name}] OFFLINE aplicado. Vencida hace {dias_vencida} dia(s).")

        # Actualizar inventario en sanitizacion
        _actualizar_estado_caducada(san_conn, bd["ID"])

        # Registrar evento
        registrar_evento(
            san_conn      = san_conn,
            id_instancia  = bd["ID_Instancia"],
            database_name = db_name,
            tipo_evento   = "CADUCAMIENTO_APLICADO",
            detalle       = {
                "caso":            bd.get("Caso"),
                "fechaExpiracion": bd["FechaExpira"].isoformat(),
                "diasVencida":     dias_vencida,
                "responsable":     bd.get("Responsable"),
            },
            status        = "OK",
            ejecutado_por = EJECUTOR,
        )
        return True

    except pyodbc.Error as e:
        log.error(f"[{nombre}] [{db_name}] Error al aplicar OFFLINE: {e}")
        registrar_evento(
            san_conn      = san_conn,
            id_instancia  = bd["ID_Instancia"],
            database_name = db_name,
            tipo_evento   = "ERROR_OPERACION",
            detalle       = {
                "operacion": "SET OFFLINE",
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


def procesar_caducidades(san_conn: pyodbc.Connection) -> dict:
    """
    Busca y aplica OFFLINE a todas las BDs vencidas.

    Returns:
        dict con resumen: total, aplicadas, errores
    """
    bases = obtener_bases_por_caducar(san_conn)

    resumen = {
        "total":    len(bases),
        "aplicadas": 0,
        "errores":  0,
    }

    if not bases:
        log.info("No hay BDs vencidas para caducar.")
        return resumen

    log.info(f"{len(bases)} BD(s) vencidas encontradas para caducar.")

    for bd in bases:
        exito = aplicar_offline(san_conn, bd)
        if exito:
            resumen["aplicadas"] += 1
        else:
            resumen["errores"] += 1

    return resumen
