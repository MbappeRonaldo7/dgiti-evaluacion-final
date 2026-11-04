"""Pruebas automatizadas del servicio (se ejecutan en el pipeline de GitHub Actions)."""
import os
import sys

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
import app as service  # noqa: E402


@pytest.fixture
def client():
    service.app.config["TESTING"] = True
    service._metadata_cache.update({
        "instance-id": "i-test123",
        "placement/availability-zone": "us-east-1a",
        "local-ipv4": "10.0.11.10",
    })
    with service.app.test_client() as c:
        yield c


class FakeCursor:
    def __init__(self, store):
        self.store = store
        self.lastrowid = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, sql, params=None):
        self.store["queries"].append(sql.strip().split()[0].upper())
        if sql.strip().upper().startswith("INSERT"):
            self.store["rows"] += 1
            self.lastrowid = self.store["rows"]

    def fetchone(self):
        return (self.store["rows"],)


class FakeConnection:
    def __init__(self, store):
        self.store = store

    def cursor(self):
        return FakeCursor(self.store)

    def close(self):
        pass


@pytest.fixture
def fake_db(monkeypatch):
    store = {"rows": 0, "queries": [], "hosts": []}

    def fake_connect(host):
        store["hosts"].append(host)
        return FakeConnection(store)

    monkeypatch.setattr(service, "get_connection", fake_connect)
    monkeypatch.setattr(service, "DB_HOST", "primary.db")
    monkeypatch.setattr(service, "DB_REPLICA_HOST", "replica.db")
    return store


# ---------------------------- pruebas unitarias ----------------------------
def test_health_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ok"
    assert body["instance_id"] == "i-test123"


def test_index_muestra_instancia(client):
    body = client.get("/").get_json()
    assert body["served_by"]["instance_id"] == "i-test123"
    assert "/health" in body["endpoints"]


def test_work_limita_iteraciones(client):
    body = client.get("/api/work?n=99999999").get_json()
    assert body["iterations"] == 200000


def test_work_parametro_invalido(client):
    assert client.get("/api/work?n=abc").status_code == 400


# ------------------------ pruebas de integración (BD simulada) -------------
def test_escritura_va_a_la_primaria(client, fake_db):
    resp = client.post("/api/visits")
    assert resp.status_code == 201
    assert resp.get_json()["written_to"] == "primary"
    assert fake_db["hosts"][0] == "primary.db"


def test_lectura_va_a_la_replica(client, fake_db):
    client.post("/api/visits")
    client.post("/api/visits")
    body = client.get("/api/visits").get_json()
    assert body["read_from"] == "replica"
    assert body["total_visits"] == 2
    assert fake_db["hosts"][-1] == "replica.db"


def test_status_con_bd_disponible(client, fake_db):
    body = client.get("/status").get_json()
    assert body["database"]["primary"]["ok"] is True
    assert body["database"]["replica"]["ok"] is True


def test_status_degradado_sin_bd(client, monkeypatch):
    def boom(host):
        raise ConnectionError("sin red")

    monkeypatch.setattr(service, "get_connection", boom)
    monkeypatch.setattr(service, "DB_HOST", "primary.db")
    resp = client.get("/status")
    assert resp.status_code == 503
    assert resp.get_json()["status"] == "degraded"
