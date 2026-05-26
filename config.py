"""
config.py
---------
Lee el archivo .env y expone la configuracion del proyecto como
constantes tipadas. Valida que las variables criticas esten presentes
al importar el modulo.

Uso:
    from config import SAN, DEST, CONN_TIMEOUT
"""

import os
from dataclasses import dataclass
from dotenv import load_dotenv

# Cargar el archivo .env indicado por ENV_FILE, por defecto ".env"
_env_file = os.getenv("ENV_FILE", ".env")
load_dotenv(
    dotenv_path=os.path.join(os.path.dirname(__file__), _env_file),
    override=False
)


@dataclass(frozen=True)
class ConexionConfig:
    host:     str
    port:     int
    database: str
    user:     str
    password: str


def _requerir(nombre: str) -> str:
    """Obtiene una variable de entorno. Falla con mensaje claro si no existe."""
    valor = os.getenv(nombre)
    if not valor:
        raise EnvironmentError(
            f"Variable de entorno requerida no encontrada: {nombre}\n"
            f"Verificar el archivo .env (usar .env.example como referencia)."
        )
    return valor


# --- Configuracion de sanitizacion ---
SAN = ConexionConfig(
    host     = _requerir("SAN_HOST"),
    port     = int(os.getenv("SAN_PORT", "1433")),
    database = _requerir("SAN_DATABASE"),
    user     = _requerir("SAN_USER"),
    password = _requerir("SAN_PASSWORD"),
)

# --- Credencial unica para instancias destino ---
DEST_USER     = _requerir("DEST_USER")
DEST_PASSWORD = _requerir("DEST_PASSWORD")

# --- Configuracion general ---
CONN_TIMEOUT        = int(os.getenv("CONN_TIMEOUT", "30"))
LOG_RETENTION_DAYS  = int(os.getenv("LOG_RETENTION_DAYS", "90"))
LOG_DIR             = os.getenv("LOG_DIR", "logs")

# --- Modo dry-run (simulacion) ---
# Si esta activo, Custodio NO ejecuta SET OFFLINE ni cambia el inventario,
# pero si registra en HISTORIAL_BASES el evento CADUCAMIENTO_SIMULADO.
# Se controla unicamente desde el .env. Para volver a ejecucion normal: DRY_RUN=0.
DRY_RUN = os.getenv("DRY_RUN", "0").strip().lower() in ("1", "true", "yes", "on")
