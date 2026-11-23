import base64

import pytest

from mock_romm.auth import CLIENT_TOKEN_RE, AuthConfig, generate_client_token


def _password_grant(client, username="admin", password="s3cret", scope="roms.read platforms.read"):
    return client.post(
        "/api/token",
        data={"grant_type": "password", "username": username, "password": password, "scope": scope},
    )


def test_heartbeat_needs_no_auth(client):
    assert client.get("/api/heartbeat").status_code == 200


def test_client_api_token(client, token_headers):
    assert client.get("/api/platforms", headers=token_headers).status_code == 200


def test_wrong_client_token_is_401(client):
    resp = client.get("/api/platforms", headers={"Authorization": "Bearer rmm_" + "0" * 64})
    assert resp.status_code == 401
    assert resp.json()["detail"]


@pytest.mark.parametrize("path", ["/api/platforms", "/api/roms", "/api/roms/1"])
def test_missing_auth_is_401_json(client, path):
    resp = client.get(path)
    assert resp.status_code == 401
    assert resp.headers["content-type"].startswith("application/json")
    assert resp.json() == {"detail": "Not authenticated"}


def test_password_grant_returns_romm_token_shape(client):
    resp = _password_grant(client)
    assert resp.status_code == 200
    body = resp.json()
    assert body["token_type"] == "bearer"
    assert isinstance(body["expires"], int) and body["expires"] > 0
    assert body["access_token"].count(".") == 2  # a JWT
    assert body["refresh_token"]


def test_access_token_authenticates(client):
    access = _password_grant(client).json()["access_token"]
    assert client.get("/api/roms", headers={"Authorization": f"Bearer {access}"}).status_code == 200


def test_refresh_token_cannot_be_used_as_access_token(client):
    refresh = _password_grant(client).json()["refresh_token"]
    assert client.get("/api/roms", headers={"Authorization": f"Bearer {refresh}"}).status_code == 401


def test_refresh_grant(client):
    refresh = _password_grant(client).json()["refresh_token"]
    resp = client.post("/api/token", data={"grant_type": "refresh_token", "refresh_token": refresh})
    assert resp.status_code == 200
    access = resp.json()["access_token"]
    assert client.get("/api/platforms", headers={"Authorization": f"Bearer {access}"}).status_code == 200


def test_refresh_grant_rejects_garbage(client):
    resp = client.post("/api/token", data={"grant_type": "refresh_token", "refresh_token": "nope"})
    assert resp.status_code == 401


def test_password_grant_wrong_password(client):
    assert _password_grant(client, password="wrong").status_code == 401


def test_password_grant_missing_fields(client):
    assert client.post("/api/token", data={"grant_type": "password"}).status_code == 400


def test_unsupported_grant(client):
    assert client.post("/api/token", data={"grant_type": "client_credentials"}).status_code == 400


def test_basic_auth(client, basic_headers):
    assert client.get("/api/roms", headers=basic_headers).status_code == 200


def test_basic_auth_wrong_password(client):
    bad = "Basic " + base64.b64encode(b"admin:nope").decode()
    assert client.get("/api/roms", headers={"Authorization": bad}).status_code == 401


def test_basic_auth_malformed(client):
    assert client.get("/api/roms", headers={"Authorization": "Basic !!!"}).status_code == 401


def test_generated_client_token_format():
    assert CLIENT_TOKEN_RE.match(generate_client_token())


def test_from_env_generates_token_when_unset(monkeypatch, capsys):
    monkeypatch.delenv("MOCK_ROMM_CLIENT_TOKEN", raising=False)
    monkeypatch.setenv("MOCK_ROMM_USER", "alice")
    cfg = AuthConfig.from_env()
    assert CLIENT_TOKEN_RE.match(cfg.client_token)
    assert cfg.username == "alice"
    assert cfg.client_token in capsys.readouterr().err


def test_from_env_uses_given_token(monkeypatch):
    token = "rmm_" + "cd" * 32
    monkeypatch.setenv("MOCK_ROMM_CLIENT_TOKEN", token)
    assert AuthConfig.from_env().client_token == token
