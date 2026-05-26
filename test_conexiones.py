# test_conexiones.py
from dotenv import load_dotenv
load_dotenv()

from db import conectar_sanitizacion, conectar_destino

print("=== Probando conexion a SAN ===")
with conectar_sanitizacion() as conn:
    cursor = conn.cursor()

    # Leer instancias activas
    cursor.execute("""
        SELECT ID_instancia, IP_server, Puerto, instancia_name, Ambiente
        FROM dbo.instancias
        WHERE Estado = 1
          AND Ambiente IS NOT NULL
        ORDER BY Ambiente, instancia_name
    """)
    instancias = cursor.fetchall()
    print(f"Instancias activas encontradas: {len(instancias)}")

print()
print("=== Probando conexion a instancias destino ===")
for inst in instancias:
    id_inst, ip, puerto, nombre, ambiente = inst
    try:
        with conectar_destino(ip, puerto, nombre) as conn:
            print(f"[OK]    [{ambiente}] {nombre} ({ip}:{puerto})")
    except Exception as e:
        print(f"[ERROR] [{ambiente}] {nombre} ({ip}:{puerto}) -> {e}")