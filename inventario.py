"""
inventario.py
-------------
Logica de sincronizacion de bases de datos desde instancias destino.

Para cada instancia activa:
  1. Lee todas las BDs del servidor (ONLINE y no ONLINE).
  2. Lee extended properties de cada BD ONLINE.
  3. Lee fecha y usuario de restore desde msdb..restorehistory.
  4. Clasifica cada BD segun sus extended properties.
  5. Hace UPSERT en noprod.INVENTARIO_BASES en sanitizacion.
  6. Registra eventos importantes en noprod.HISTORIAL_BASES.

Clasificacion de estados:
  ACTIVA               RSE con FechaExpira presente
  PRORROGADA           RSE con FechaExpira presente y al menos una prorroga registrada
  RE_CONTROLADA        RE (enmascarada), no caduca
  SIN_ETIQUETAR        Sin extended properties (alerta)
  RSE_SIN_FECHA        RSE pero sin FechaExpira (alerta)
  OFFLINE_DESCONOCIDA  BD existe pero no esta ONLINE (no fue Custodio quien la puso asi)
  ELIMINADA            BD que estaba en inventario y ya no existe en el servidor

Deteccion de cambios:
  - Cambio en propiedades (caso, fecha): registra ETIQUETAS_ACTUALIZADAS con motivo
    "posible modificacion directa" y ventana de tiempo.
  - Cambio solo en estado (flujo normal, ej: PRORROGADA->ACTIVA): registra
    ETIQUETAS_ACTUALIZADAS con motivo "Cambio de estado detectado por Custodio".
  - Ambos casos se registran por separado para no generar falsos positivos.
"""

import re
import json
import pyodbc
from datetime import date, datetime
from typing import Optional

from db import conectar_sanitizacion, conectar_destino
from logger import get_logger

log = get_logger(__name__)

# BDs de sistema que siempre se excluyen
BASES_SISTEMA = {"master", "tempdb", "model", "msdb", "dbdba"}

# Nombres de extended properties que leemos
EP_CASO        = "Caso"
EP_DBA         = "DBA"
EP_RAZON       = "Razon"
EP_RESPONSABLE = "Responsable"
EP_FECHA_EXP   = "Fecha_Expiracion"


# =============================================================================
# LECTURA DESDE INSTANCIA DESTINO
# =============================================================================

def obtener_todas_las_bases(conn: pyodbc.Connection) -> list[dict]:
    """
    Retorna todas las BDs del servidor con su estado,
    excluyendo las de sistema. Incluye ONLINE y no ONLINE.
    """
    sql = """
        SELECT name, state_desc
        FROM sys.databases
        WHERE name NOT IN ({placeholders})
        ORDER BY name
    """.format(
        placeholders=", ".join(["?" for _ in BASES_SISTEMA])
    )
    cursor = conn.cursor()
    cursor.execute(sql, list(BASES_SISTEMA))
    return [{"name": row.name, "state_desc": row.state_desc} for row in cursor.fetchall()]


def obtener_extended_properties(conn: pyodbc.Connection, database: str) -> dict:
    """
    Lee las 5 extended properties de control de una BD especifica.
    Solo llamar cuando la BD esta ONLINE.
    """
    sql = f"""
        SELECT name, CAST(value AS NVARCHAR(500)) AS value
        FROM [{database}].sys.extended_properties
        WHERE class     = 0
          AND major_id  = 0
          AND minor_id  = 0
          AND name IN (?, ?, ?, ?, ?)
    """
    cursor = conn.cursor()
    try:
        cursor.execute(sql, [EP_CASO, EP_DBA, EP_RAZON, EP_RESPONSABLE, EP_FECHA_EXP])
        props = {row.name: row.value for row in cursor.fetchall()}
    except pyodbc.Error as e:
        log.warning(f"No se pudieron leer extended properties de [{database}]: {e}")
        props = {}

    return {
        "caso":         props.get(EP_CASO),
        "dba":          props.get(EP_DBA),
        "razon":        props.get(EP_RAZON),
        "responsable":  props.get(EP_RESPONSABLE),
        "fecha_expira": props.get(EP_FECHA_EXP),
    }


def obtener_restore_info(conn: pyodbc.Connection, database: str) -> dict:
    """
    Lee la fecha y usuario del ultimo restore de la BD desde msdb.
    Busca primero con el nombre exacto, luego sin sufijo _BPMxxxxx.
    Funciona aunque la BD este OFFLINE.
    """
    nombre_base = re.sub(r'_BPM\d+$', '', database, flags=re.IGNORECASE)

    sql = """
        SELECT TOP 1
            rh.restore_date,
            rh.user_name
        FROM msdb.dbo.restorehistory rh
        INNER JOIN msdb.dbo.backupset bs ON rh.backup_set_id = bs.backup_set_id
        WHERE rh.destination_database_name IN (?, ?)
        ORDER BY rh.restore_date DESC
    """
    cursor = conn.cursor()
    try:
        cursor.execute(sql, [database, nombre_base])
        row = cursor.fetchone()
        if row:
            return {
                "fecha_restore":   row.restore_date,
                "usuario_restore": row.user_name,
            }
    except pyodbc.Error as e:
        log.warning(f"No se pudo leer restorehistory de [{database}]: {e}")

    return {"fecha_restore": None, "usuario_restore": None}


# =============================================================================
# CLASIFICACION
# =============================================================================

def clasificar_bd(props: dict) -> tuple[str, str]:
    """
    Clasifica una BD segun sus extended properties.
    Retorna (Estado, EstadoMotivo).
    """
    razon = (props.get("razon") or "").strip()
    fecha = props.get("fecha_expira")
    caso  = props.get("caso")

    # Sin ningun marcador
    if not caso and not razon:
        return "SIN_ETIQUETAR", "ETIQUETADO_FALTANTE"

    # Restaurar Sin Enmascarar (verificar primero porque contiene "enmascarar")
    if "sin enmascarar" in razon.lower():
        if not fecha:
            return "RSE_SIN_FECHA", "FECHA_FALTANTE"
        return "ACTIVA", "BD_NUEVA"

    # Restaurar Enmascarado
    if "enmascarado" in razon.lower():
        return "RE_CONTROLADA", "BD_NUEVA"

    # Razon presente pero no reconocida
    return "SIN_ETIQUETAR", "ETIQUETADO_FALTANTE"


def parse_razon_codigo(razon: Optional[str]) -> Optional[str]:
    """Convierte el texto de Razon a codigo RSE / RE / None."""
    if not razon:
        return None
    r = razon.lower()
    if "sin enmascarar" in r:
        return "RSE"
    if "enmascarado" in r:
        return "RE"
    return None


def parse_fecha(fecha_str: Optional[str]) -> Optional[date]:
    """Convierte string de fecha a objeto date. Acepta YYYY-MM-DD."""
    if not fecha_str:
        return None
    try:
        return date.fromisoformat(fecha_str.strip())
    except ValueError:
        log.warning(f"Formato de fecha no reconocido: {fecha_str}")
        return None


# =============================================================================
# UPSERT EN SANITIZACION
# =============================================================================

def upsert_inventario(
    san_conn:       pyodbc.Connection,
    id_instancia:   int,
    ambiente:       str,
    database_name:  str,
    props:          dict,
    restore_info:   dict,
    estado:         str,
    estado_motivo:  str,
) -> tuple[bool, Optional[str], Optional[str], Optional[date], Optional[object]]:
    """
    INSERT si la BD no existe en INVENTARIO_BASES, UPDATE si ya existe.
    Retorna (es_nueva, estado_anterior, caso_anterior, fecha_anterior, ultimo_check_anterior).
    """
    cursor = san_conn.cursor()
    cursor.execute("""
        SELECT ID, Estado, Caso, FechaExpira, UltimoCheck
        FROM noprod.INVENTARIO_BASES
        WHERE ID_Instancia = ? AND DatabaseName = ?
    """, [id_instancia, database_name])
    existente = cursor.fetchone()

    razon_codigo = parse_razon_codigo(props.get("razon"))
    fecha_expira = parse_fecha(props.get("fecha_expira"))

    if existente:
        estado_previo = existente.Estado

        cursor.execute("""
            UPDATE noprod.INVENTARIO_BASES
            SET Ambiente          = ?,
                Caso              = COALESCE(?, Caso),
                DBA               = COALESCE(?, DBA),
                RazonCodigo       = COALESCE(?, RazonCodigo),
                Responsable       = COALESCE(?, Responsable),
                FechaExpira       = COALESCE(?, FechaExpira),
                Estado            = ?,
                EstadoMotivo      = CASE WHEN Estado <> ? THEN ? ELSE EstadoMotivo END,
                FechaRestore      = COALESCE(?, FechaRestore),
                UsuarioRestore    = COALESCE(?, UsuarioRestore),
                UltimoCheck       = SYSDATETIME(),
                FechaCambioEstado = CASE WHEN Estado <> ? THEN SYSDATETIME()
                                         ELSE FechaCambioEstado END
            WHERE ID_Instancia = ? AND DatabaseName = ?
        """, [
            ambiente,
            props.get("caso"),
            props.get("dba"),
            razon_codigo,
            props.get("responsable"),
            fecha_expira,
            estado,
            estado,
            estado_motivo,
            restore_info.get("fecha_restore"),
            restore_info.get("usuario_restore"),
            estado,
            id_instancia,
            database_name,
        ])
        san_conn.commit()

        # Si estaba ELIMINADA, es una nueva carga aunque la fila ya existia
        if estado_previo == 'ELIMINADA':
            return True, None, None, None, None

        return False, estado_previo, existente.Caso, existente.FechaExpira, existente.UltimoCheck
    else:
        cursor.execute("""
            INSERT INTO noprod.INVENTARIO_BASES
                (ID_Instancia, Ambiente, DatabaseName, Caso, DBA, RazonCodigo,
                 Responsable, FechaExpira, Estado, EstadoMotivo,
                 FechaRestore, UsuarioRestore, FechaCambioEstado)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, SYSDATETIME())
        """, [
            id_instancia,
            ambiente,
            database_name,
            props.get("caso"),
            props.get("dba"),
            razon_codigo,
            props.get("responsable"),
            fecha_expira,
            estado,
            estado_motivo,
            restore_info.get("fecha_restore"),
            restore_info.get("usuario_restore"),
        ])
        san_conn.commit()
        return True, None, None, None, None


def registrar_evento(
    san_conn:      pyodbc.Connection,
    id_instancia:  int,
    database_name: Optional[str],
    tipo_evento:   str,
    detalle:       dict,
    status:        str,
    ejecutado_por: str,
) -> None:
    """Inserta un evento en noprod.HISTORIAL_BASES."""
    cursor = san_conn.cursor()
    cursor.execute("""
        INSERT INTO noprod.HISTORIAL_BASES
            (ID_Instancia, DatabaseName, TipoEvento, Detalle, Status, EjecutadoPor)
        VALUES (?, ?, ?, ?, ?, ?)
    """, [
        id_instancia,
        database_name,
        tipo_evento,
        json.dumps(detalle, default=str, ensure_ascii=False),
        status,
        ejecutado_por,
    ])
    san_conn.commit()


# =============================================================================
# PROCESO PRINCIPAL DE SINCRONIZACION
# =============================================================================

def sincronizar_instancia(instancia: dict) -> dict:
    """
    Sincroniza todas las BDs de una instancia destino con INVENTARIO_BASES.
    """
    id_inst  = instancia["ID_instancia"]
    host     = instancia["IP_server"]
    port     = instancia["Puerto"]
    nombre   = instancia["instancia_name"]
    ambiente = instancia["Ambiente"]
    ejecutor = "caducidad.py"

    resumen = {
        "instancia":  nombre,
        "procesadas": 0,
        "nuevas":     0,
        "alertas":    0,
        "errores":    0,
        "conectado":  False,
    }

    try:
        with conectar_destino(host, port, nombre) as dest_conn:
            resumen["conectado"] = True
            bases = obtener_todas_las_bases(dest_conn)
            log.info(f"[{nombre}] {len(bases)} BDs encontradas.")

            with conectar_sanitizacion() as san_conn:

                _marcar_desaparecidas(san_conn, dest_conn, id_inst, bases, nombre, ejecutor)

                for bd in bases:
                    db_name    = bd["name"]
                    state_desc = bd["state_desc"]
                    try:
                        # BD no accesible: registrar sin leer extended properties
                        if state_desc != "ONLINE":
                            restore_info = obtener_restore_info(dest_conn, db_name)
                            es_nueva, estado_anterior, _, _, ultimo_check_anterior = upsert_inventario(
                                san_conn      = san_conn,
                                id_instancia  = id_inst,
                                ambiente      = ambiente,
                                database_name = db_name,
                                props         = {},
                                restore_info  = restore_info,
                                estado        = "OFFLINE_DESCONOCIDA",
                                estado_motivo = "BD_" + state_desc,
                            )
                            if es_nueva:
                                resumen["nuevas"] += 1
                                registrar_evento(
                                    san_conn      = san_conn,
                                    id_instancia  = id_inst,
                                    database_name = db_name,
                                    tipo_evento   = "BD_DESCUBIERTA",
                                    detalle       = {
                                        "ambiente":       ambiente,
                                        "estado":         "OFFLINE_DESCONOCIDA",
                                        "stateDesc":      state_desc,
                                        "caso":           None,
                                        "razonCodigo":    None,
                                        "fechaRestore":   restore_info.get("fecha_restore"),
                                        "usuarioRestore": restore_info.get("usuario_restore"),
                                    },
                                    status        = "OK",
                                    ejecutado_por = ejecutor,
                                )
                                log.warning(
                                    f"[{nombre}] [{db_name}] BD en estado {state_desc}. "
                                    f"Registrada como OFFLINE_DESCONOCIDA."
                                )
                            elif estado_anterior and estado_anterior != "OFFLINE_DESCONOCIDA":
                                registrar_evento(
                                    san_conn      = san_conn,
                                    id_instancia  = id_inst,
                                    database_name = db_name,
                                    tipo_evento   = "ETIQUETAS_ACTUALIZADAS",
                                    detalle       = {
                                        "estadoAnterior": estado_anterior,
                                        "estadoNuevo":    "OFFLINE_DESCONOCIDA",
                                        "motivo":         "BD encontrada en estado " + state_desc,
                                    },
                                    status        = "OK",
                                    ejecutado_por = ejecutor,
                                )
                                log.warning(
                                    f"[{nombre}] [{db_name}] "
                                    f"Estado cambio: {estado_anterior} -> OFFLINE_DESCONOCIDA."
                                )
                            resumen["procesadas"] += 1
                            continue

                        # BD ONLINE: flujo normal
                        props        = obtener_extended_properties(dest_conn, db_name)
                        restore_info = obtener_restore_info(dest_conn, db_name)
                        estado, motivo = clasificar_bd(props)

                        es_nueva, estado_anterior, caso_anterior, fecha_anterior, ultimo_check_anterior = upsert_inventario(
                            san_conn      = san_conn,
                            id_instancia  = id_inst,
                            ambiente      = ambiente,
                            database_name = db_name,
                            props         = props,
                            restore_info  = restore_info,
                            estado        = estado,
                            estado_motivo = motivo,
                        )

                        resumen["procesadas"] += 1

                        if es_nueva:
                            resumen["nuevas"] += 1
                            registrar_evento(
                                san_conn      = san_conn,
                                id_instancia  = id_inst,
                                database_name = db_name,
                                tipo_evento   = "BD_DESCUBIERTA",
                                detalle       = {
                                    "ambiente":       ambiente,
                                    "estado":         estado,
                                    "caso":           props.get("caso"),
                                    "razonCodigo":    parse_razon_codigo(props.get("razon")),
                                    "fechaRestore":   restore_info.get("fecha_restore"),
                                    "usuarioRestore": restore_info.get("usuario_restore"),
                                },
                                status        = "OK",
                                ejecutado_por = ejecutor,
                            )
                            log.info(f"[{nombre}] [{db_name}] BD nueva detectada. Estado: {estado}.")

                        elif not es_nueva:
                            # Evaluar que cambio: propiedades, estado, o ambos
                            cambio_props = (
                                (props.get("caso") is not None and str(caso_anterior) != str(props.get("caso")))
                                or
                                (props.get("fecha_expira") is not None and str(fecha_anterior) != str(parse_fecha(props.get("fecha_expira"))))
                            )
                            cambio_estado = estado_anterior != estado

                            if cambio_props:
                                # Cambio en propiedades — posible modificacion directa
                                registrar_evento(
                                    san_conn      = san_conn,
                                    id_instancia  = id_inst,
                                    database_name = db_name,
                                    tipo_evento   = "ETIQUETAS_ACTUALIZADAS",
                                    detalle       = {
                                        "estadoAnterior": estado_anterior,
                                        "estadoNuevo":    estado,
                                        "casoAnterior":   str(caso_anterior),
                                        "casoNuevo":      props.get("caso"),
                                        "fechaAnterior":  str(fecha_anterior),
                                        "fechaNueva":     props.get("fecha_expira"),
                                        "motivo":         "Cambio detectado - posible modificacion directa. Revisar logs del servidor.",
                                    },
                                    status        = "OK",
                                    ejecutado_por = ejecutor,
                                )
                                log.warning(
                                    f"[{nombre}] [{db_name}] Cambio en propiedades detectado. "
                                    f"Caso: {caso_anterior} -> {props.get('caso')}. "
                                    f"Fecha: {fecha_anterior} -> {props.get('fecha_expira')}."
                                )

                            elif cambio_estado:
                                # Solo cambio de estado — flujo normal de Custodio
                                registrar_evento(
                                    san_conn      = san_conn,
                                    id_instancia  = id_inst,
                                    database_name = db_name,
                                    tipo_evento   = "ETIQUETAS_ACTUALIZADAS",
                                    detalle       = {
                                        "estadoAnterior": estado_anterior,
                                        "estadoNuevo":    estado,
                                        "motivo":         "Cambio de estado detectado por Custodio",
                                    },
                                    status        = "OK",
                                    ejecutado_por = ejecutor,
                                )
                                log.info(
                                    f"[{nombre}] [{db_name}] "
                                    f"Estado cambio: {estado_anterior} -> {estado}."
                                )

                        if estado in ("SIN_ETIQUETAR", "RSE_SIN_FECHA"):
                            resumen["alertas"] += 1
                            if es_nueva:
                                log.warning(
                                    f"[{nombre}] [{db_name}] ALERTA: {estado}. "
                                    f"Restaurada por: {restore_info.get('usuario_restore', 'desconocido')}."
                                )

                    except Exception as e:
                        resumen["errores"] += 1
                        log.error(f"[{nombre}] [{db_name}] Error procesando BD: {e}")
                        registrar_evento(
                            san_conn      = san_conn,
                            id_instancia  = id_inst,
                            database_name = db_name,
                            tipo_evento   = "ERROR_OPERACION",
                            detalle       = {"error": str(e)},
                            status        = "ERROR",
                            ejecutado_por = ejecutor,
                        )

    except pyodbc.Error as e:
        resumen["errores"] += 1
        log.error(f"[{nombre}] Error de conexion: {e}")
        with conectar_sanitizacion() as san_conn:
            registrar_evento(
                san_conn      = san_conn,
                id_instancia  = id_inst,
                database_name = None,
                tipo_evento   = "ERROR_CONEXION",
                detalle       = {
                    "host":   host,
                    "puerto": int(port),
                    "error":  str(e),
                },
                status        = "ERROR",
                ejecutado_por = ejecutor,
            )

    return resumen


def _marcar_desaparecidas(
    san_conn:     pyodbc.Connection,
    dest_conn:    pyodbc.Connection,
    id_instancia: int,
    todas_bases:  list[dict],
    nombre:       str,
    ejecutor:     str,
) -> None:
    """
    Detecta BDs que estaban en INVENTARIO_BASES pero ya no existen
    en el servidor destino. Las marca con BD_DESAPARECIDA en historial
    y ELIMINADA en inventario.
    """
    nombres_en_servidor = {b["name"] for b in todas_bases}

    cursor = san_conn.cursor()
    cursor.execute("""
        SELECT DatabaseName, Estado, Caso, FechaExpira, Responsable, DBA
        FROM noprod.INVENTARIO_BASES
        WHERE ID_Instancia = ?
          AND Estado NOT IN ('CADUCADA', 'ELIMINADA')
    """, [id_instancia])
    en_inventario = {
        row.DatabaseName: {
            "estado":      row.Estado,
            "caso":        row.Caso,
            "fechaExpira": row.FechaExpira.isoformat() if row.FechaExpira else None,
            "responsable": row.Responsable,
            "dba":         row.DBA,
        }
        for row in cursor.fetchall()
    }

    desaparecidas = en_inventario.keys() - nombres_en_servidor

    for db_name in desaparecidas:
        ultimo = en_inventario[db_name]
        log.warning(f"[{nombre}] [{db_name}] BD desaparecida del servidor.")
        registrar_evento(
            san_conn      = san_conn,
            id_instancia  = id_instancia,
            database_name = db_name,
            tipo_evento   = "BD_DESAPARECIDA",
            detalle       = {
                "ultimoEstado": ultimo["estado"],
                "caso":         ultimo["caso"],
                "fechaExpira":  ultimo["fechaExpira"],
                "responsable":  ultimo["responsable"],
                "dba":          ultimo["dba"],
            },
            status        = "OK",
            ejecutado_por = ejecutor,
        )
        cursor.execute("""
            UPDATE noprod.INVENTARIO_BASES
            SET Estado            = 'ELIMINADA',
                EstadoMotivo      = 'BD_ELIMINADA',
                FechaCambioEstado = SYSDATETIME(),
                UltimoCheck       = SYSDATETIME()
            WHERE ID_Instancia = ? AND DatabaseName = ?
        """, [id_instancia, db_name])
        san_conn.commit()