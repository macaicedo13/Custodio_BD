"""
db.py
-----
Manejo centralizado de conexiones pyodbc a SQL Server.
Provee funciones para conectarse a sanitizacion y a instancias destino.

Uso:
    from db import conectar_sanitizacion, conectar_destino

    with conectar_sanitizacion() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT ...")

    with conectar_destino(host, port) as conn:
        ...
"""

import pyodbc
from contextlib import contextmanager
from typing import Generator

from config import SAN, DEST_USER, DEST_PASSWORD, CONN_TIMEOUT
from logger import get_logger

log = get_logger(__name__)

# Driver ODBC - ajustar segun version instalada en el servidor
ODBC_DRIVER = "ODBC Driver 17 for SQL Server"


def _build_connection_string(
    host: str,
    port: int,
    database: str,
    user: str,
    password: str,
    timeout: int = CONN_TIMEOUT
) -> str:
    return (
        f"DRIVER={{{ODBC_DRIVER}}};"
        f"SERVER={host},{port};"
        f"DATABASE={database};"
        f"UID={user};"
        f"PWD={password};"
        f"Connection Timeout={timeout};"
        f"TrustServerCertificate=yes;"   # ambientes no prod pueden tener certs autofirmados
    )


@contextmanager
def conectar_sanitizacion() -> Generator[pyodbc.Connection, None, None]:
    """
    Conexion al servidor de sanitizacion (DBCUSTODIO).
    Uso con context manager para garantizar cierre automatico.
    """
    conn = None
    try:
        conn_str = _build_connection_string(
            host     = SAN.host,
            port     = SAN.port,
            database = SAN.database,
            user     = SAN.user,
            password = SAN.password,
        )
        conn = pyodbc.connect(conn_str, autocommit=False)
        yield conn
    except pyodbc.Error as e:
        log.error(f"Error conectando a sanitizacion ({SAN.host}): {e}")
        raise
    finally:
        if conn:
            conn.close()


@contextmanager
def conectar_destino(
    host: str,
    port: int,
    instance_name: str = ""
) -> Generator[pyodbc.Connection, None, None]:
    """
    Conexion a una instancia destino (DEV / QA / PROVEEDORES).
    Usa la credencial unica definida en .env.

    Args:
        host:          IP del servidor destino.
        port:          Puerto SQL Server.
        instance_name: Nombre legible para logging.
    """
    conn = None
    label = instance_name or host
    try:
        conn_str = _build_connection_string(
            host     = host,
            port     = port,
            database = "master",   #conectamos a master para ver sys.databases
            user     = DEST_USER,
            password = DEST_PASSWORD,
        )
        conn = pyodbc.connect(conn_str, autocommit=False)
        log.info(f"[{label}] Conexion establecida.")
        yield conn
    except pyodbc.Error as e:
        log.error(f"[{label}] Error de conexion: {e}")
        raise
    finally:
        if conn:
            conn.close()
            log.info(f"[{label}] Conexion cerrada.")