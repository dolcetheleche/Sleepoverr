"""resolve_igdb_ids.py against mocked HTTP only (the sandbox it was written in had no IGDB access)."""

import json
import shutil

import httpx
import pytest
import respx

import resolve_igdb_ids as r
from mock_romm.data import FIXTURES_DIR, load_library


@pytest.fixture
def fixtures(tmp_path):
    for name in ("platforms.json", "roms.json"):
        shutil.copy(FIXTURES_DIR / name, tmp_path / name)
    return tmp_path


def test_best_match_prefers_exact_name():
    results = [{"id": 1, "name": "Super Mario World 2"}, {"id": 2, "name": "Super Mario World"}]
    assert r.best_match("Super Mario World", results)["id"] == 2
    assert r.best_match("Something", results)["id"] == 1
    assert r.best_match("x", []) is None


def test_title_for_unidentified_uses_filename():
    assert r.title_for({"name": None, "fs_name": "Contra (USA).nes"}) == "Contra"


@respx.mock
def test_resolve_writes_ids(fixtures, monkeypatch):
    respx.post(r.TWITCH_TOKEN_URL).mock(return_value=httpx.Response(200, json={"access_token": "tok"}))
    queries = []

    def games(request):
        body = request.content.decode()
        queries.append(body)
        assert request.headers["Client-ID"] == "cid" and request.headers["Authorization"] == "Bearer tok"
        title = body.split('"')[1]
        return httpx.Response(200, json=[{"id": 1000 + len(queries), "name": title}])

    respx.post(r.IGDB_GAMES_URL).mock(side_effect=games)
    monkeypatch.setenv("IGDB_CLIENT_ID", "cid")
    monkeypatch.setenv("IGDB_CLIENT_SECRET", "secret")
    monkeypatch.setattr(r, "REQUEST_INTERVAL", 0)
    monkeypatch.setattr(r.time, "sleep", lambda _s: None)

    assert r.main(["--fixtures-dir", str(fixtures)]) == 0

    resolved = json.loads((fixtures / "roms.resolved.json").read_text())
    identified = [x for x in resolved if not x["is_unidentified"]]
    assert len(queries) == len(identified) == 32
    assert all(isinstance(x["igdb_id"], int) for x in identified)
    assert all(x["igdb_id"] is None for x in resolved if x["is_unidentified"])
    assert 'search "Super Mario World"; fields id,name; where platforms = (19);' in "\n".join(queries)
    # the mock prefers the resolved file when present
    assert load_library(fixtures).source.name == "roms.resolved.json"
    assert load_library(fixtures, prefer_resolved=False).source.name == "roms.json"


@respx.mock
def test_dry_run_writes_nothing(fixtures, monkeypatch):
    respx.post(r.TWITCH_TOKEN_URL).mock(return_value=httpx.Response(200, json={"access_token": "tok"}))
    respx.post(r.IGDB_GAMES_URL).mock(return_value=httpx.Response(200, json=[]))
    monkeypatch.setenv("IGDB_CLIENT_ID", "cid")
    monkeypatch.setenv("IGDB_CLIENT_SECRET", "secret")
    monkeypatch.setattr(r.time, "sleep", lambda _s: None)
    assert r.main(["--dry-run", "--fixtures-dir", str(fixtures)]) == 0
    assert not (fixtures / "roms.resolved.json").exists()


def test_missing_credentials(monkeypatch):
    monkeypatch.delenv("IGDB_CLIENT_ID", raising=False)
    monkeypatch.delenv("IGDB_CLIENT_SECRET", raising=False)
    assert r.main([]) == 2


def test_quotes_are_escaped():
    with respx.mock:
        route = respx.post(r.IGDB_GAMES_URL).mock(return_value=httpx.Response(200, json=[]))
        with httpx.Client() as c:
            r.search_game(c, "cid", "tok", 'Say "hi"', None)
        assert route.calls[0].request.content.decode() == 'search "Say \\"hi\\""; fields id,name; limit 10;'
