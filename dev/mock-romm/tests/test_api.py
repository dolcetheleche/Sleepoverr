from datetime import datetime

import pytest

ROM_USER_KEYS = {
    "id",
    "user_id",
    "rom_id",
    "difficulty",
    "rating",
    "completion",
    "created_at",
    "updated_at",
    "last_played",
    "is_main_sibling",
    "backlogged",
    "now_playing",
    "hidden",
    "status",
    "user__username",
}
PLAY_KEYS = {"last_played", "status", "rating", "completion", "backlogged", "now_playing"}
SIMPLE_ROM_KEYS = {
    "id",
    "igdb_id",
    "sgdb_id",
    "moby_id",
    "ss_id",
    "ra_id",
    "launchbox_id",
    "hasheous_id",
    "tgdb_id",
    "hltb_id",
    "flashpoint_id",
    "gamelist_id",
    "platform_id",
    "platform_slug",
    "platform_fs_slug",
    "platform_display_name",
    "platform_custom_name",
    "fs_name",
    "fs_name_no_tags",
    "fs_name_no_ext",
    "fs_extension",
    "fs_path",
    "fs_size_bytes",
    "name",
    "slug",
    "summary",
    "youtube_video_id",
    "alternative_names",
    "regions",
    "languages",
    "tags",
    "merged_screenshots",
    "metadatum",
    "igdb_metadata",
    "path_cover_small",
    "path_cover_large",
    "url_cover",
    "path_manual",
    "url_manual",
    "revision",
    "has_manual",
    "is_unidentified",
    "is_identified",
    "is_identifying",
    "missing_from_fs",
    "has_notes",
    "has_simple_single_file",
    "has_nested_single_file",
    "has_multiple_files",
    "crc_hash",
    "md5_hash",
    "sha1_hash",
    "files",
    "siblings",
    "full_path",
    "created_at",
    "updated_at",
    "rom_user",
}


def get_roms(client, headers, **params):
    resp = client.get("/api/roms", headers=headers, params=params)
    assert resp.status_code == 200, resp.text
    return resp.json()


# -- heartbeat / platforms ---------------------------------------------------------------
def test_heartbeat_shape(client):
    body = client.get("/api/heartbeat").json()
    assert set(body) >= {"SYSTEM", "METADATA_SOURCES", "FILESYSTEM", "EMULATION", "FRONTEND", "OIDC", "TASKS"}
    assert body["SYSTEM"] == {"VERSION": "mock-1.0", "GIT_BRANCH": None, "SHOW_SETUP_WIZARD": False}
    assert body["OIDC"]["ENABLED"] is False and body["OIDC"]["PROVIDER"] == ""
    assert all(isinstance(v, bool) for v in body["METADATA_SOURCES"].values())
    assert set(body["FILESYSTEM"]["FS_PLATFORMS"]) == {"nes", "snes", "genesis", "gba", "psx", "n64"}


def test_platforms(client, token_headers):
    platforms = client.get("/api/platforms", headers=token_headers).json()
    assert len(platforms) == 6
    required = {
        "id",
        "slug",
        "fs_slug",
        "name",
        "display_name",
        "custom_name",
        "igdb_id",
        "igdb_slug",
        "rom_count",
        "fs_size_bytes",
        "category",
        "family_name",
        "family_slug",
        "generation",
        "url_logo",
        "aspect_ratio",
        "is_unidentified",
        "is_identified",
        "missing_from_fs",
        "firmware",
        "created_at",
        "updated_at",
    }
    for p in platforms:
        assert required <= set(p)
        assert p["custom_name"] is None and p["url_logo"] is None and p["firmware"] == []
        assert p["aspect_ratio"] == "2 / 3"
    by_slug = {p["fs_slug"]: p for p in platforms}
    assert {s: by_slug[s]["igdb_id"] for s in by_slug} == {
        "nes": 18,
        "snes": 19,
        "genesis": 29,
        "gba": 24,
        "psx": 7,
        "n64": 4,
    }
    assert sum(p["rom_count"] for p in platforms) == 40


def test_openapi_and_docs(client):
    assert client.get("/openapi.json").json()["info"]["title"] == "Mock RomM API"
    assert client.get("/api/docs").status_code == 200


# -- roms: envelope & pagination --------------------------------------------------------
def test_envelope_exact_keys(client, token_headers):
    body = get_roms(client, token_headers)
    assert set(body) == {"items", "total", "limit", "offset", "char_index", "rom_id_index", "filter_values"}
    assert body["limit"] == 50 and body["offset"] == 0
    assert body["total"] == 39  # 40 fixtures minus the one hidden ROM
    assert len(body["items"]) == 39
    assert body["rom_id_index"] == [r["id"] for r in body["items"]]
    assert body["filter_values"] == {}
    assert body["char_index"]["S"] < body["char_index"]["T"]


def test_items_are_simple_rom_schema(client, token_headers):
    for rom in get_roms(client, token_headers)["items"]:
        assert SIMPLE_ROM_KEYS <= set(rom), SIMPLE_ROM_KEYS - set(rom)
        assert set(rom["rom_user"]) >= ROM_USER_KEYS
        assert not (PLAY_KEYS & set(rom)), "play data must only live in rom_user"
        assert rom["igdb_id"] is None
        assert set(rom["metadatum"]) >= {
            "genres",
            "companies",
            "franchises",
            "collections",
            "game_modes",
            "age_ratings",
            "first_release_date",
            "average_rating",
        }


def test_limit_offset(client, token_headers):
    full = get_roms(client, token_headers, limit=10000)["items"]
    page = get_roms(client, token_headers, limit=5, offset=5)
    assert page["limit"] == 5 and page["offset"] == 5 and page["total"] == len(full)
    assert [r["id"] for r in page["items"]] == [r["id"] for r in full[5:10]]
    assert get_roms(client, token_headers, offset=1000)["items"] == []


@pytest.mark.parametrize("params", [{"limit": 0}, {"limit": 10001}, {"offset": -1}, {"order_dir": "sideways"}])
def test_invalid_params(client, token_headers, params):
    assert client.get("/api/roms", headers=token_headers, params=params).status_code == 422


# -- ordering ---------------------------------------------------------------------------
def test_default_order_is_name_asc(client, token_headers):
    names = [(r["name"] or r["fs_name"]).lower() for r in get_roms(client, token_headers)["items"]]
    assert names == sorted(names)


@pytest.mark.parametrize("field", ["updated_at", "created_at", "fs_size_bytes", "name"])
@pytest.mark.parametrize("direction", ["asc", "desc"])
def test_order_by(client, token_headers, field, direction):
    items = get_roms(client, token_headers, order_by=field, order_dir=direction)["items"]

    def key(r):
        if field == "name":
            return (r["name"] or r["fs_name"]).lower()
        if field.endswith("_at"):
            return datetime.fromisoformat(r[field].replace("Z", "+00:00"))
        return r[field]

    values = [key(r) for r in items]
    assert values == sorted(values, reverse=direction == "desc")


def test_char_index_only_for_name_sort(client, token_headers):
    assert get_roms(client, token_headers, order_by="updated_at")["char_index"] == {}


# -- filters ----------------------------------------------------------------------------
def test_search_term(client, token_headers):
    body = get_roms(client, token_headers, search_term="zelda")
    assert body["total"] == 4
    assert all("zelda" in r["fs_name"].lower() for r in body["items"])


def test_search_term_matches_filename_of_unidentified(client, token_headers):
    body = get_roms(client, token_headers, search_term="contra")
    assert [r["fs_name"] for r in body["items"]] == ["Contra (USA).nes"]
    assert body["items"][0]["name"] is None


def test_platform_ids_repeatable(client, token_headers):
    body = client.get("/api/roms?platform_ids=1&platform_ids=6", headers=token_headers).json()
    assert {r["platform_id"] for r in body["items"]} == {1, 6}
    assert body["total"] == 8 + 7 - 1  # one N64 ROM is hidden


def test_updated_after(client, token_headers):
    cutoff = "2026-10-01T00:00:00Z"
    body = get_roms(client, token_headers, updated_after=cutoff, limit=10000)
    assert 0 < body["total"] < 39
    cut = datetime.fromisoformat(cutoff.replace("Z", "+00:00"))
    for r in body["items"]:
        assert datetime.fromisoformat(r["updated_at"].replace("Z", "+00:00")) > cut


def test_updated_after_naive_datetime_is_utc(client, token_headers):
    a = get_roms(client, token_headers, updated_after="2026-10-01T00:00:00")["total"]
    b = get_roms(client, token_headers, updated_after="2026-10-01T00:00:00+00:00")["total"]
    assert a == b


def test_matched_filter(client, token_headers):
    unmatched = get_roms(client, token_headers, matched=False)["items"]
    assert len(unmatched) == 8
    assert all(r["is_unidentified"] and r["name"] is None for r in unmatched)
    assert all(r["is_identified"] for r in get_roms(client, token_headers, matched=True)["items"])


def test_last_played_filter(client, token_headers):
    played = get_roms(client, token_headers, last_played=True)["items"]
    never = get_roms(client, token_headers, last_played=False)["items"]
    assert played and never
    assert all(r["rom_user"]["last_played"] is not None for r in played)
    assert all(r["rom_user"]["last_played"] is None for r in never)
    assert len(played) + len(never) == 39


@pytest.mark.parametrize("st", ["incomplete", "finished", "completed_100", "retired", "never_playing"])
def test_statuses_filter_single(client, token_headers, st):
    items = get_roms(client, token_headers, statuses=st)["items"]
    assert items and all(r["rom_user"]["status"] == st for r in items)


def test_statuses_filter_repeatable_is_or(client, token_headers):
    body = client.get("/api/roms?statuses=finished&statuses=completed_100", headers=token_headers).json()
    assert {r["rom_user"]["status"] for r in body["items"]} == {"finished", "completed_100"}


def test_statuses_pseudo_values(client, token_headers):
    assert all(r["rom_user"]["now_playing"] for r in get_roms(client, token_headers, statuses="now_playing")["items"])
    assert all(r["rom_user"]["backlogged"] for r in get_roms(client, token_headers, statuses="backlogged")["items"])
    hidden = get_roms(client, token_headers, statuses="hidden")["items"]
    assert [r["id"] for r in hidden] == [37]


# -- rom_user ---------------------------------------------------------------------------
def test_rom_user_spread(client, token_headers):
    users = [r["rom_user"] for r in get_roms(client, token_headers)["items"]]
    statuses = {u["status"] for u in users}
    assert statuses >= {None, "incomplete", "finished", "completed_100"}
    assert any(u["now_playing"] for u in users) and any(u["backlogged"] for u in users)
    assert len({u["rating"] for u in users}) >= 5
    assert all(0 <= u["rating"] <= 10 and 0 <= u["completion"] <= 100 for u in users)


def test_untouched_rom_gets_romm_placeholder_rom_user(client, token_headers):
    rom = client.get("/api/roms/10", headers=token_headers).json()
    assert rom["rom_user"]["id"] == -1 and rom["rom_user"]["rom_id"] == -1
    assert rom["rom_user"]["last_played"] is None and rom["rom_user"]["status"] is None


def test_touched_rom_user_links_rom(client, token_headers):
    rom = client.get("/api/roms/1", headers=token_headers).json()
    assert rom["rom_user"]["rom_id"] == 1 and rom["rom_user"]["user_id"] == 1
    assert rom["rom_user"]["status"] == "incomplete"


# -- detail -----------------------------------------------------------------------------
def test_rom_detail(client, token_headers):
    rom = client.get("/api/roms/9", headers=token_headers).json()
    assert rom["name"] == "Super Mario World"
    assert rom["fs_name"] == "Super Mario World (USA).sfc"
    assert rom["fs_extension"] == "sfc" and rom["fs_name_no_tags"] == "Super Mario World"
    assert rom["full_path"] == "roms/snes/Super Mario World (USA).sfc"
    assert rom["regions"] == ["USA"]
    for key in ("user_saves", "user_states", "user_screenshots", "user_collections", "all_user_notes"):
        assert rom[key] == []


def test_rom_detail_404(client, token_headers):
    resp = client.get("/api/roms/99999", headers=token_headers)
    assert resp.status_code == 404
    assert "not found" in resp.json()["detail"]
