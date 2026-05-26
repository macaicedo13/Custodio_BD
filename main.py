"""
main.py
-------
Orquestador principal del proceso nocturno de caducidad.

Flujo:
  1. Leer instancias activas desde dbo.instancias en sanitizacion.
  2. Para cada instancia: sincronizar BDs (inventario.py).
  3. Aplicar OFFLINE a BDs vencidas (caducidad.py).
  4. Imprimir resumen final.

Ejecucion:
  python main.py

Programacion (Task Scheduler de Windows):
  Programa : python.exe
  Argumentos: C:\\caducidad_bds\\main.py
  Inicio en : C:\\caducidad_bds
  Hora      : 02:00 AM diario
"""

import sys
from datetime import datetime

from db import conectar_sanitizacion
from inventario import sincronizar_instancia
from caducidad import procesar_caducidades
from logger import get_logger

log = get_logger(__name__)


def obtener_instancias(san_conn) -> list[dict]:
    """
    Lee todas las instancias activas con Ambiente definido
    desde dbo.instancias en sanitizacion.
    """
    sql = """
        SELECT
            ID_instancia,
            IP_server,
            Puerto,
            instancia_name,
            Ambiente
        FROM dbo.instancias
        WHERE Estado   = 1
          AND Ambiente IS NOT NULL
        ORDER BY Ambiente, instancia_name
    """
    cursor = san_conn.cursor()
    cursor.execute(sql)
    cols = [col[0] for col in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]


def main():
    inicio = datetime.now()
    log.info("=" * 60)
    log.info("INICIO DEL PROCESO DE CADUCIDAD")
    log.info(f"Fecha/Hora : {inicio.strftime('%Y-%m-%d %H:%M:%S')}")
    log.info("=" * 60)

    resumen_global = {
        "instancias_procesadas": 0,
        "instancias_error":      0,
        "bds_procesadas":        0,
        "bds_nuevas":            0,
        "bds_alertas":           0,
        "bds_caducadas":         0,
        "errores_caducidad":     0,
    }

    try:
        with conectar_sanitizacion() as san_conn:

            # --- Paso 1: Obtener instancias ---
            instancias = obtener_instancias(san_conn)

            if not instancias:
                log.warning("No se encontraron instancias activas con Ambiente definido.")
                log.warning("Verificar tabla dbo.instancias: Estado=1 y Ambiente no nulo.")
                sys.exit(0)

            log.info(f"Instancias activas encontradas: {len(instancias)}")

            # --- Paso 2: Sincronizar inventario por instancia ---
            log.info("-" * 60)
            log.info("PASO 1: Sincronizando inventario de BDs")
            log.info("-" * 60)

            for instancia in instancias:
                nombre = instancia["instancia_name"]
                log.info(f"Procesando instancia: {nombre} ({instancia['Ambiente']})")

                resumen = sincronizar_instancia(instancia)

                if resumen["conectado"]:
                    resumen_global["instancias_procesadas"] += 1
                    resumen_global["bds_procesadas"]        += resumen["procesadas"]
                    resumen_global["bds_nuevas"]            += resumen["nuevas"]
                    resumen_global["bds_alertas"]           += resumen["alertas"]
                    log.info(
                        f"[{nombre}] Procesadas: {resumen['procesadas']} | "
                        f"Nuevas: {resumen['nuevas']} | "
                        f"Alertas: {resumen['alertas']} | "
                        f"Errores: {resumen['errores']}"
                    )
                else:
                    resumen_global["instancias_error"] += 1
                    log.error(f"[{nombre}] No se pudo conectar. Ver log para detalles.")

            # --- Paso 3: Aplicar caducidades ---
            log.info("-" * 60)
            log.info("PASO 2: Aplicando caducidades")
            log.info("-" * 60)

            resumen_cad = procesar_caducidades(san_conn)
            resumen_global["bds_caducadas"]     = resumen_cad["aplicadas"]
            resumen_global["errores_caducidad"] = resumen_cad["errores"]

            if resumen_cad["total"] == 0:
                log.info("Sin BDs vencidas para caducar.")
            else:
                log.info(
                    f"Vencidas encontradas: {resumen_cad['total']} | "
                    f"Caducadas: {resumen_cad['aplicadas']} | "
                    f"Errores: {resumen_cad['errores']}"
                )

    except Exception as e:
        log.critical(f"Error critico en el proceso principal: {e}", exc_info=True)
        sys.exit(1)

    # --- Resumen final ---
    fin      = datetime.now()
    duracion = (fin - inicio).seconds

    log.info("=" * 60)
    log.info("RESUMEN FINAL")
    log.info(f"Duracion               : {duracion} segundos")
    log.info(f"Instancias procesadas  : {resumen_global['instancias_procesadas']}")
    log.info(f"Instancias con error   : {resumen_global['instancias_error']}")
    log.info(f"BDs sincronizadas      : {resumen_global['bds_procesadas']}")
    log.info(f"BDs nuevas detectadas  : {resumen_global['bds_nuevas']}")
    log.info(f"BDs con alerta         : {resumen_global['bds_alertas']}")
    log.info(f"BDs caducadas (OFFLINE): {resumen_global['bds_caducadas']}")
    log.info(f"Errores de caducidad   : {resumen_global['errores_caducidad']}")
    log.info("=" * 60)

    # Codigo de salida: 0 = OK, 1 = hubo errores (util para Task Scheduler)
    if resumen_global["instancias_error"] > 0 or resumen_global["errores_caducidad"] > 0:
        log.warning("El proceso finalizo con errores. Revisar log.")
        sys.exit(1)

    log.info("Proceso finalizado correctamente.")
    sys.exit(0)


if __name__ == "__main__":
    main()
