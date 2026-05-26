"""
logger.py
---------
Configuracion centralizada de logging para el proyecto caducidad_bds.
Un archivo de log por dia con rotacion automatica.
Formato: timestamp | nivel | modulo | mensaje

Uso:
    from logger import get_logger
    log = get_logger(__name__)
    log.info("Mensaje informativo")
    log.error("Mensaje de error")
"""

import logging
import os
from logging.handlers import TimedRotatingFileHandler
from datetime import datetime


def get_logger(name: str) -> logging.Logger:
    """
    Retorna un logger configurado con handlers de consola y archivo.
    Si el logger ya fue configurado previamente, retorna el existente.
    """
    logger = logging.getLogger(name)

    # Evitar agregar handlers duplicados si se llama varias veces
    if logger.handlers:
        return logger

    logger.setLevel(logging.INFO)

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)-8s | %(name)-20s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    # --- Handler de consola ---
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(formatter)

    # --- Handler de archivo con rotacion diaria ---
    log_dir = os.getenv("LOG_DIR", "logs")
    os.makedirs(log_dir, exist_ok=True)

    log_path = os.path.join(log_dir, "caducidad.log")

    file_handler = TimedRotatingFileHandler(
        filename=log_path,
        when="midnight",
        interval=1,
        backupCount=int(os.getenv("LOG_RETENTION_DAYS", "90")),
        encoding="utf-8"
    )
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(formatter)
    file_handler.suffix = "%Y-%m-%d"

    logger.addHandler(console_handler)
    logger.addHandler(file_handler)

    return logger
