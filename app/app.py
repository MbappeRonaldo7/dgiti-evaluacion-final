"""
Servicio de la evaluación final - DGITI (UPB)
API Flask desplegada detrás de un Application Load Balancer en AWS.

Endpoints:
  GET  /             -> información del servicio y de la instancia que respondió
  GET  /health       -> endpoint de validación usado por el ALB (no depende de la BD)
  GET  /status       -> estado detallado: conexión a la BD primaria y a la réplica
  POST /api/visits   -> registra una visita (ESCRITURA en la BD primaria)
  GET  /api/visits   -> cuenta las visitas (LECTURA desde la réplica)
  GET  /api/work     -> trabajo de CPU controlado, usado en la prueba de carga
"""
import hashlib
import os
import socket
import time
import urllib.request

from flask import Flask, jsonify, request

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
DB_HOST = os.getenv("DB_HOST", "")
DB_REPLICA_HOST = os.getenv("DB_REPLICA_HOST", "")
DB_USER = os.getenv("DB_USER", "")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")
DB_NAME = os.getenv("DB_NAME", "appdb")

_metadata_cache = {}


# --------------------------------------------------------------------------
# Metadatos de la instancia EC2 (IMDSv2). Permite ver qué instancia respondió.
# --------------------------------------------------------------------------
def _imds(path):
    if path in _metadata_cache:
        return _metadata_cache[path]
    try:
        token_req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
        )
        token = urllib.request.urlopen(token_req, timeout=0.5).read().decode()
        req = urllib.request.Request(
            f"http://169.254.169.254/latest/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
        )
        value = urllib.request.urlopen(req, timeout=0.5).read().decode()
    except Exception:
        value = "local"
    _metadata_cache[path] = value
    return value


def instance_info():
    return {
        "instance_id": _imds("instance-id"),
        "availability_zone": _imds("placement/availability-zone"),
        "private_ip": _imds("local-ipv4"),
        "hostname": socket.gethostname(),
    }


# --------------------------------------------------------------------------
# Base de datos (MySQL en RDS). Escrituras -> primaria, lecturas -> réplica.
# --------------------------------------------------------------------------
def get_connection(host):
    import pymysql  # import diferido: las pruebas unitarias no necesitan MySQL

    return pymysql.connect(
        host=host,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        connect_timeout=3,
        autocommit=True,
    )


def ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute(
            """CREATE TABLE IF NOT EXISTS visits (
                   id INT AUTO_INCREMENT PRIMARY KEY,
                   instance_id VARCHAR(64) NOT NULL,
                   created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
               )"""
        )


def check_db(host):
    if not host:
        return {"ok": False, "error": "host no configurado"}
    start = time.time()
    try:
        conn = get_connection(host)
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        conn.close()
        return {"ok": True, "latency_ms": round((time.time() - start) * 1000, 2)}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": type(exc).__name__}


# --------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------
@app.get("/")
def index():
    return jsonify(
        service="dgiti-evaluacion-final",
        version=APP_VERSION,
        served_by=instance_info(),
        endpoints=["/health", "/status", "/api/visits", "/api/work"],
    )


@app.get("/health")
def health():
    # El ALB usa este endpoint. No depende de la BD para que una caída de la BD
    # no saque de servicio a todas las instancias.
    info = instance_info()
    return jsonify(status="ok", instance_id=info["instance_id"],
                   availability_zone=info["availability_zone"]), 200


@app.get("/status")
def status():
    primary = check_db(DB_HOST)
    replica = check_db(DB_REPLICA_HOST)
    code = 200 if primary["ok"] else 503
    return jsonify(
        status="ok" if primary["ok"] else "degraded",
        version=APP_VERSION,
        served_by=instance_info(),
        database={"primary": primary, "replica": replica},
    ), code


@app.post("/api/visits")
def create_visit():
    info = instance_info()
    try:
        conn = get_connection(DB_HOST)
        ensure_schema(conn)
        with conn.cursor() as cur:
            cur.execute("INSERT INTO visits (instance_id) VALUES (%s)",
                        (info["instance_id"],))
            new_id = cur.lastrowid
        conn.close()
    except Exception as exc:  # noqa: BLE001
        return jsonify(error="no se pudo escribir en la BD primaria",
                       detail=type(exc).__name__), 503
    return jsonify(id=new_id, written_to="primary",
                   served_by=info["instance_id"]), 201


@app.get("/api/visits")
def count_visits():
    source = "replica" if DB_REPLICA_HOST else "primary"
    host = DB_REPLICA_HOST or DB_HOST
    try:
        conn = get_connection(host)
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM visits")
            total = cur.fetchone()[0]
        conn.close()
    except Exception as exc:  # noqa: BLE001
        return jsonify(error=f"no se pudo leer de la BD ({source})",
                       detail=type(exc).__name__), 503
    return jsonify(total_visits=total, read_from=source,
                   served_by=instance_info()["instance_id"])


@app.get("/api/work")
def work():
    # Simula una operación costosa en CPU. n controla la carga (máx. 200000).
    try:
        n = int(request.args.get("n", 20000))
    except ValueError:
        return jsonify(error="n debe ser un entero"), 400
    n = max(1, min(n, 200000))
    start = time.time()
    digest = b"dgiti"
    for _ in range(n):
        digest = hashlib.sha256(digest).digest()
    return jsonify(iterations=n,
                   elapsed_ms=round((time.time() - start) * 1000, 2),
                   result=digest.hex()[:16],
                   served_by=instance_info()["instance_id"])


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
