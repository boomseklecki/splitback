"""Relay: registration (issue + per-IP limit), /push auth + forwarding + dead-token return, and the
ES256 provider JWT. No real APNs calls — `apns.send` is monkeypatched."""
import base64
import re

import jwt as pyjwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import apns, db
from app.config import settings
from app.main import app


@pytest.fixture
def client(tmp_path):
    settings.db_path = str(tmp_path / "relay.db")
    db.init()
    with TestClient(app) as c:
        yield c


def _register(client, ip: str):
    return client.post("/register", data={"email": "a@x.com", "instance": "house"},
                       headers={"X-Forwarded-For": ip})


def test_register_issues_key_then_rate_limits(client):
    resp = _register(client, "1.1.1.1")
    assert resp.status_code == 200
    assert "relaysk_" in resp.text                       # key shown once
    for _ in range(settings.register_max_per_hour):
        last = _register(client, "1.1.1.1")
    assert last.status_code == 429                        # per-IP limit hit


def test_push_rejects_bad_key(client):
    resp = client.post("/push", json={"tokens": ["t"], "title": "x", "body": "y"},
                       headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401


def test_push_503_when_unconfigured(client):
    key = db.create_key("a@x.com", None)
    resp = client.post("/push", json={"tokens": ["t"], "title": "x", "body": "y"},
                       headers={"Authorization": f"Bearer {key}"})
    assert resp.status_code == 503                        # APNs creds absent


def test_push_forwards_and_returns_dead(client, monkeypatch):
    key = db.create_key("a@x.com", None)
    saved = (settings.apns_key_id, settings.apns_team_id, settings.apns_bundle_id, settings.apns_auth_key)
    settings.apns_key_id, settings.apns_team_id = "K", "T"
    settings.apns_bundle_id, settings.apns_auth_key = "com.splitback.app", "x"

    async def fake_send(_client, token, title, body):
        return token == "dead-token"                     # one token is dead
    monkeypatch.setattr(apns, "send", fake_send)
    try:
        resp = client.post("/push", json={"tokens": ["good", "dead-token"], "title": "Hi", "body": "yo"},
                           headers={"Authorization": f"Bearer {key}"})
        assert resp.status_code == 200
        assert resp.json()["dead"] == ["dead-token"]
    finally:
        (settings.apns_key_id, settings.apns_team_id,
         settings.apns_bundle_id, settings.apns_auth_key) = saved


def test_provider_token_builds():
    pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    saved = (settings.apns_key_id, settings.apns_team_id, settings.apns_auth_key)
    apns._token_cache = None
    settings.apns_key_id, settings.apns_team_id = "KID", "TEAM"
    settings.apns_auth_key = base64.b64encode(pem).decode()
    try:
        header = pyjwt.get_unverified_header(apns._provider_token())
        assert header["alg"] == "ES256" and header["kid"] == "KID"
    finally:
        settings.apns_key_id, settings.apns_team_id, settings.apns_auth_key = saved
        apns._token_cache = None


def test_health(client):
    assert client.get("/health").json()["status"] == "ok"
