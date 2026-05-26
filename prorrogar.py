"""
prorrogar.py
------------
Script de prorroga de BDs caducadas o proximas a caducar.
Se ejecuta manualmente por el DBA cuando llega un caso aprobado.

Acciones que realiza:
  1. Valida que la BD exista en INVENTARIO_BASES.
  2. Valida que el caso nuevo sea diferente al caso actual.
  3. Valida que la nueva fecha sea mayor a la fecha actual registrada.
  4. Valida que la BD sea de tipo RSE (RE no caduca, no requiere prorroga).
  5. Si la BD esta OFFLINE (CADUCADA u OFFLINE_DESCONOCIDA): la trae ONLINE.
  6. Actualiza las extended properties Caso y Fecha_Expiracion en la BD destino.
  7. Actualiza INVENTARIO_BASES: FechaExpira, Estado, Caso.
  8. Registra evento PRORROGA_REGISTRADA en HISTORIAL_BASES.
  9. Si hubo reactivacion, registra tambien REACTIVACION.

Uso:
  python prorrogar.py ^
    --instancia-id   26 ^
    --bd             DBEJEMPLO_CASO33208 ^
    --caso-nuevo     35100 ^
    --fecha-nueva    2026-06-01 ^
    --motivo         "Caso sigue en revision por compliance" ^
    --aprobado-por   "Ana Morales"

Parametros:
  --instancia-id  ID de la instancia en dbo.instancias (columna ID_instancia)
  --bd            Nombre exacto de la base de datos
  --caso-nuevo    Numero del nuevo caso que aprueba la prorroga
  --fecha-nueva   Nueva fecha de expiracion en formato YYYY-MM-DD
  --motivo        Motivo de la prorroga (entre comillas si tiene espacios)
  --aprobado-por  Nombre del aprobador (entre comillas)
"""

import argparse
import sys
import getpass
from datetime import date

import pyodbc

from db import conectar_sanitizacion, conectar_destino
from inventario import registrar_evento
from logger import get_logger

log = get_logger(__name__)

# Estados que indican que la BD esta OFFLINE y debe traerse ONLINE
ESTADOS_OFFLINE = ("CADUCADA", "OFFLINE_DESCONOCIDA")


# =============================================================================
# LECTURA DE DATOS ACTUALES
# =============================================================================

def obtener_bd_inventario(san_conn: pyodbc.Connection, id_instancia: int, db_name: str) -> dict | None:
    """Obtiene el registro actual de la BD en INVENTARIO_BASES."""
    sql = """
        SELECT
            inv.ID,
            inv.ID_Instancia,
            inv.DatabaseName,
            inv.Caso,
            inv.Estado,
            inv.FechaExpira,
            inv.RazonCodigo,
            i.IP_server,
            i.Puerto,
            i.instancia_name,
            i.Ambiente
        FROM noprod.INVENTARIO_BASES inv
        INNER JOIN dbo.instancias i ON inv.ID_Instancia = i.ID_instancia
        WHERE inv.ID_Instancia = ?
          AND inv.DatabaseName = ?
    """
    cursor = san_conn.cursor()
    cursor.execute(sql, [id_instancia, db_name])
    row = cursor.fetchone()
    if not row:
        return None
    cols = [col[0] for col in cursor.description]
    return dict(zip(cols, row))


# =============================================================================
# OPERACIONES EN SERVIDOR DESTINO
# =============================================================================

def traer_online(dest_conn: pyodbc.Connection, db_name: str) -> None:
    """Trae una BD de OFFLINE a ONLINE."""
    dest_conn.autocommit = True
    cursor = dest_conn.cursor()

    cursor.execute("SELECT state_desc FROM sys.databases WHERE name = ?", [db_name])
    row = cursor.fetchone()

    if not row:
        raise ValueError(f"La BD [{db_name}] no existe en el servidor destino.")

    if row.state_desc == "ONLINE":
        log.info(f"La BD [{db_name}] ya esta ONLINE.")
        return

    cursor.execute(f"ALTER DATABASE [{db_name}] SET ONLINE")
    log.info(f"BD [{db_name}] traida a ONLINE correctamente.")


def actualizar_extended_property(
    dest_conn: pyodbc.Connection,
    db_name:   str,
    prop_name: str,
    valor:     str,
) -> None:
    """Actualiza o crea una extended property en la BD destino."""
    sql = f"""
        USE [{db_name}];
        IF EXISTS (
            SELECT 1 FROM sys.extended_properties
            WHERE name = ? AND class = 0 AND major_id = 0 AND minor_id = 0
        )
            EXEC sys.sp_updateextendedproperty @name = ?, @value = ?;
        ELSE
            EXEC sys.sp_addextendedproperty @name = ?, @value = ?;
    """
    dest_conn.autocommit = True
    cursor = dest_conn.cursor()
    cursor.execute(sql, [prop_name, prop_name, valor, prop_name, valor])
    log.info(f"Extended property [{prop_name}] actualizada en [{db_name}].")


# =============================================================================
# ACTUALIZACION EN SANITIZACION
# =============================================================================

def actualizar_inventario_prorroga(
    san_conn:    pyodbc.Connection,
    inv_id:      int,
    caso_nuevo:  str,
    fecha_nueva: date,
) -> None:
    """Actualiza INVENTARIO_BASES con los datos de la prorroga."""
    sql = """
        UPDATE noprod.INVENTARIO_BASES
        SET Caso              = ?,
            FechaExpira       = ?,
            Estado            = 'PRORROGADA',
            EstadoMotivo      = 'PRORROGA_APLICADA',
            FechaCambioEstado = SYSDATETIME(),
            UltimoCheck       = SYSDATETIME()
        WHERE ID = ?
    """
    cursor = san_conn.cursor()
    cursor.execute(sql, [caso_nuevo, fecha_nueva, inv_id])
    san_conn.commit()


# =============================================================================
# FLUJO PRINCIPAL
# =============================================================================

def prorrogar(
    id_instancia: int,
    db_name:      str,
    caso_nuevo:   str,
    fecha_nueva:  date,
    motivo:       str,
    aprobado_por: str,
) -> None:
    """
    Ejecuta el proceso completo de prorroga.
    """
    ejecutado_por = getpass.getuser()

    log.info("=" * 60)
    log.info("INICIO DE PRORROGA")
    log.info(f"Instancia ID : {id_instancia}")
    log.info(f"BD           : {db_name}")
    log.info(f"Caso nuevo   : {caso_nuevo}")
    log.info(f"Fecha nueva  : {fecha_nueva}")
    log.info(f"Aprobado por : {aprobado_por}")
    log.info(f"Ejecutado por: {ejecutado_por}")
    log.info("=" * 60)

    with conectar_sanitizacion() as san_conn:

        # --- Validacion 1: BD existe en inventario ---
        bd = obtener_bd_inventario(san_conn, id_instancia, db_name)
        if not bd:
            log.error(
                f"La BD [{db_name}] no se encuentra en INVENTARIO_BASES "
                f"para la instancia ID {id_instancia}."
            )
            log.error("Verificar que el ID de instancia y el nombre de BD sean correctos.")
            sys.exit(1)

        nombre    = bd["instancia_name"]
        host      = bd["IP_server"]
        port      = bd["Puerto"]
        caso_ant  = bd["Caso"]
        fecha_ant = bd["FechaExpira"]
        estado    = bd["Estado"]

        log.info(f"BD encontrada en inventario.")
        log.info(f"Instancia  : {nombre} ({bd['Ambiente']})")
        log.info(f"Estado     : {estado}")
        log.info(f"Caso actual: {caso_ant}")
        log.info(f"Fecha actual: {fecha_ant}")

        # --- Validacion 2: caso nuevo debe ser diferente al actual ---
        if caso_nuevo == caso_ant:
            log.error(
                f"El caso nuevo ({caso_nuevo}) es igual al caso actual. "
                f"Una prorroga siempre debe tener un nuevo caso aprobado."
            )
            sys.exit(1)

        # --- Validacion 3: fecha nueva > fecha actual ---
        if fecha_ant and fecha_nueva <= fecha_ant:
            log.error(
                f"La nueva fecha ({fecha_nueva}) debe ser mayor "
                f"a la fecha actual registrada ({fecha_ant})."
            )
            sys.exit(1)

        # --- Validacion 4: solo aplica a RSE ---
        if bd["RazonCodigo"] == "RE":
            log.error(
                f"La BD [{db_name}] es de tipo RE (Restaurar Enmascarado). "
                f"Las BDs enmascaradas no tienen fecha de expiracion y no requieren prorroga."
            )
            sys.exit(1)

        # --- Confirmar accion ---
        es_reactivacion = estado in ESTADOS_OFFLINE
        print()
        print(f"  BD          : {db_name}")
        print(f"  Instancia   : {nombre}")
        print(f"  Estado      : {estado}")
        print(f"  Caso actual : {caso_ant}  ->  Nuevo: {caso_nuevo}")
        print(f"  Fecha actual: {fecha_ant}  ->  Nueva: {fecha_nueva}")
        print(f"  Motivo      : {motivo}")
        print(f"  Aprobado por: {aprobado_por}")
        if es_reactivacion:
            print(f"  ATENCION    : La BD esta OFFLINE y sera traida ONLINE.")
        print()
        confirmacion = input("Confirmar prorroga? (s/n): ").strip().lower()

        if confirmacion != "s":
            log.info("Prorroga cancelada por el usuario.")
            sys.exit(0)

        # --- Paso 1: Traer ONLINE si es necesario (conexion separada) ---
        if es_reactivacion:
            log.info(f"BD esta {estado} (OFFLINE). Trayendo ONLINE...")
            with conectar_destino(host, port, nombre) as dest_conn:
                traer_online(dest_conn, db_name)
            # Conexion cerrada intencionalmente antes de actualizar
            # extended properties. SQL Server necesita que la BD este
            # completamente ONLINE antes de permitir USE [BD].

        # --- Paso 2: Actualizar extended properties (nueva conexion) ---
        fecha_nueva_str = fecha_nueva.isoformat()
        with conectar_destino(host, port, nombre) as dest_conn:
            actualizar_extended_property(dest_conn, db_name, "Caso",             caso_nuevo)
            actualizar_extended_property(dest_conn, db_name, "Fecha_Expiracion", fecha_nueva_str)

        # --- Paso 3: Actualizar inventario en sanitizacion ---
        actualizar_inventario_prorroga(
            san_conn    = san_conn,
            inv_id      = bd["ID"],
            caso_nuevo  = caso_nuevo,
            fecha_nueva = fecha_nueva,
        )

        # --- Paso 4: Registrar eventos en historial ---
        registrar_evento(
            san_conn      = san_conn,
            id_instancia  = id_instancia,
            database_name = db_name,
            tipo_evento   = "PRORROGA_REGISTRADA",
            detalle       = {
                "caso":          caso_nuevo,
                "casoAnterior":  caso_ant,
                "fechaAnterior": str(fecha_ant),
                "fechaNueva":    str(fecha_nueva),
                "motivo":        motivo,
                "aprobadoPor":   aprobado_por,
                "reactivacion":  es_reactivacion,
            },
            status        = "OK",
            ejecutado_por = ejecutado_por,
        )

        if es_reactivacion:
            registrar_evento(
                san_conn      = san_conn,
                id_instancia  = id_instancia,
                database_name = db_name,
                tipo_evento   = "REACTIVACION",
                detalle       = {
                    "caso":        caso_nuevo,
                    "estadoAntes": estado,
                    "motivo":      motivo,
                    "aprobadoPor": aprobado_por,
                },
                status        = "OK",
                ejecutado_por = ejecutado_por,
            )

    log.info("=" * 60)
    log.info("PRORROGA COMPLETADA EXITOSAMENTE")
    log.info(f"BD [{db_name}] en [{nombre}]")
    log.info(f"Nueva fecha de expiracion: {fecha_nueva}")
    log.info(f"Nuevo caso: {caso_nuevo}")
    log.info("=" * 60)


# =============================================================================
# ENTRADA POR LINEA DE COMANDOS
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Prorrogar la fecha de expiracion de una BD no productiva.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ejemplos:
  python prorrogar.py --instancia-id 26 --bd DBEJEMPLO_CASO33208 ^
    --caso-nuevo 35100 --fecha-nueva 2026-06-01 ^
    --motivo "Caso en revision" --aprobado-por "Ana Morales"
        """
    )

    parser.add_argument(
        "--instancia-id", type=int, required=True,
        help="ID de la instancia en dbo.instancias"
    )
    parser.add_argument(
        "--bd", type=str, required=True,
        help="Nombre exacto de la base de datos"
    )
    parser.add_argument(
        "--caso-nuevo", type=str, required=True,
        help="Numero del nuevo caso aprobado"
    )
    parser.add_argument(
        "--fecha-nueva", type=date.fromisoformat, required=True,
        help="Nueva fecha de expiracion (YYYY-MM-DD)"
    )
    parser.add_argument(
        "--motivo", type=str, required=True,
        help="Motivo de la prorroga"
    )
    parser.add_argument(
        "--aprobado-por", type=str, required=True,
        help="Nombre del aprobador del caso"
    )

    args = parser.parse_args()

    prorrogar(
        id_instancia = args.instancia_id,
        db_name      = args.bd,
        caso_nuevo   = args.caso_nuevo,
        fecha_nueva  = args.fecha_nueva,
        motivo       = args.motivo,
        aprobado_por = args.aprobado_por,
    )


if __name__ == "__main__":
    main()