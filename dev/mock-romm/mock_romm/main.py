"""Mock RomM server: the read-only slice of the RomM REST API Sleepoverr's sync will use.

Run locally:  uvicorn --factory mock_romm.main:create_app --port 8080
OpenAPI:      /openapi.json      Swagger UI: /api/docs
"""

from datetime import UTC, datetime
from typing import Annotated, Any, Literal

from fastapi import Depends, FastAPI, Form, HTTPException, Query, Request, status

from mock_romm.auth import AuthConfig
from mock_romm.data import FIXTURES_DIR, Library, load_library, parse_dt, to_detailed

ORDERABLE = ("name", "updated_at", "created_at", "fs_size_bytes")


def _heartbeat(library: Library) -> dict[str, Any]:
    fs_platforms = [p["fs_slug"] for p in library.platforms]
    return {
        "SYSTEM": {"VERSION": "mock-1.0", "GIT_BRANCH": None, "SHOW_SETUP_WIZARD": False},
        "METADATA_SOURCES": {
            "ANY_SOURCE_ENABLED": False,
            "IGDB_API_ENABLED": False,
            "SS_API_ENABLED": False,
            "SS_DEV_CREDENTIALS_SET": False,
            "MOBY_API_ENABLED": False,
            "STEAMGRIDDB_API_ENABLED": False,
            "RA_API_ENABLED": False,
            "LAUNCHBOX_API_ENABLED": False,
            "HASHEOUS_API_ENABLED": False,
            "PLAYMATCH_API_ENABLED": False,
            "TGDB_API_ENABLED": False,
            "FLASHPOINT_API_ENABLED": False,
            "HLTB_API_ENABLED": False,
        },
        "FILESYSTEM": {
            "FS_PLATFORMS": fs_platforms,
            "FS_PLATFORM_SLUGS": {s: s for s in fs_platforms},
            "TITLE_ID_EXTRACTION_ENABLED": False,
        },
        "EMULATION": {
            "DISABLE_EMULATOR_JS": True,
            "DISABLE_RUFFLE_RS": True,
            "EJS_CORES": {},
        },
        "FRONTEND": {
            "UPLOAD_TIMEOUT": 600,
            "DISABLE_USERPASS_LOGIN": False,
            "YOUTUBE_BASE_URL": "https://www.youtube.com",
        },
        "OIDC": {"ENABLED": False, "AUTOLOGIN": False, "PROVIDER": "", "RP_INITIATED_LOGOUT": False},
        "TASKS": {
            "ENABLE_SCHEDULED_RESCAN": False,
            "SCHEDULED_RESCAN_CRON": "0 3 * * *",
            "ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB": False,
            "SCHEDULED_UPDATE_SWITCH_TITLEDB_CRON": "0 4 * * *",
            "ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA": False,
            "SCHEDULED_UPDATE_LAUNCHBOX_METADATA_CRON": "0 5 * * *",
            "ENABLE_SCHEDULED_CONVERT_IMAGES_TO_WEBP": False,
            "SCHEDULED_CONVERT_IMAGES_TO_WEBP_CRON": "0 4 * * *",
        },
    }


def _sort_key(order_by: str):
    if order_by == "name":
        return lambda r: (r["name"] or r["fs_name"]).lower()
    if order_by in ("updated_at", "created_at"):
        return lambda r: parse_dt(r[order_by])
    return lambda r: r[order_by]


def _char_index(items: list[dict[str, Any]]) -> dict[str, int]:
    index: dict[str, int] = {}
    for pos, rom in enumerate(items):
        first = (rom["name"] or rom["fs_name"])[:1].upper()
        letter = first if first.isalpha() else "#"
        index.setdefault(letter, pos)
    return index


def _matches_statuses(rom_user: dict[str, Any], statuses: list[str]) -> bool:
    # Same semantics as RomM: OR across the selected values; now_playing / backlogged /
    # hidden are pseudo-statuses backed by their boolean columns.
    for wanted in statuses:
        if wanted in ("now_playing", "backlogged", "hidden"):
            if rom_user[wanted]:
                return True
        elif rom_user["status"] == wanted:
            return True
    return False


def create_app(auth: AuthConfig | None = None, library: Library | None = None) -> FastAPI:
    auth = auth or AuthConfig.from_env()
    library = library or load_library(FIXTURES_DIR)

    app = FastAPI(
        title="Mock RomM API",
        version="mock-1.0",
        description="Read-only imitation of the RomM REST API for testing Sleepoverr's RomM sync.",
        docs_url="/api/docs",
        redoc_url=None,
        openapi_url="/openapi.json",
    )
    app.state.auth = auth
    app.state.library = library

    def require_auth(request: Request) -> str:
        return auth.authenticate(request)

    Authed = Annotated[str, Depends(require_auth)]

    @app.get("/api/heartbeat", tags=["system"])
    def heartbeat() -> dict[str, Any]:
        return _heartbeat(library)

    @app.post("/api/token", tags=["auth"])
    def token(
        grant_type: Annotated[str, Form()] = "password",
        username: Annotated[str | None, Form()] = None,
        password: Annotated[str | None, Form()] = None,
        scope: Annotated[str, Form()] = "",
        refresh_token: Annotated[str | None, Form()] = None,
    ) -> dict[str, Any]:
        scopes = scope.split()
        if grant_type == "password":
            if not username or not password:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Missing username or password")
            if username != auth.username or password != auth.password:
                raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Invalid username or password")
            return auth.issue_tokens(scopes)
        if grant_type == "refresh_token":
            if not refresh_token:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Missing refresh token")
            claims = auth.decode(refresh_token, "refresh")
            if claims is None:
                raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
            return auth.issue_tokens(str(claims.get("scopes", "")).split())
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Invalid or unsupported grant type")

    @app.get("/api/platforms", tags=["platforms"])
    def platforms(_: Authed) -> list[dict[str, Any]]:
        return library.platforms

    @app.get("/api/roms", tags=["roms"])
    def roms(
        _: Authed,
        limit: Annotated[int, Query(ge=1, le=10000)] = 50,
        offset: Annotated[int, Query(ge=0)] = 0,
        order_by: str = "name",
        order_dir: Literal["asc", "desc"] = "asc",
        search_term: str | None = None,
        platform_ids: Annotated[list[int] | None, Query()] = None,
        updated_after: datetime | None = None,
        matched: bool | None = None,
        last_played: bool | None = None,
        statuses: Annotated[list[str] | None, Query()] = None,
        with_char_index: bool = True,
        with_rom_id_index: bool = True,
    ) -> dict[str, Any]:
        order_by = order_by.lower() if order_by.lower() in ORDERABLE else "name"
        items = list(library.roms)
        if platform_ids:
            items = [r for r in items if r["platform_id"] in platform_ids]
        if search_term:
            needle = search_term.lower()
            items = [r for r in items if needle in (r["name"] or "").lower() or needle in r["fs_name"].lower()]
        if updated_after is not None:
            cutoff = updated_after if updated_after.tzinfo else updated_after.replace(tzinfo=UTC)
            items = [r for r in items if parse_dt(r["updated_at"]) > cutoff]
        if matched is not None:
            items = [r for r in items if r["is_identified"] is matched]
        if last_played is not None:
            items = [r for r in items if (r["rom_user"]["last_played"] is not None) is last_played]
        if statuses:
            items = [r for r in items if _matches_statuses(r["rom_user"], statuses)]
        if not statuses or "hidden" not in statuses:
            items = [r for r in items if not r["rom_user"]["hidden"]]

        items.sort(key=lambda r: r["id"])  # stable tiebreaker
        items.sort(key=_sort_key(order_by), reverse=order_dir == "desc")

        return {
            "items": items[offset : offset + limit],
            "total": len(items),
            "limit": limit,
            "offset": offset,
            "char_index": _char_index(items) if with_char_index and order_by == "name" else {},
            "rom_id_index": [r["id"] for r in items] if with_rom_id_index else [],
            "filter_values": {},
        }

    @app.get("/api/roms/{rom_id}", tags=["roms"])
    def rom_detail(rom_id: int, _: Authed) -> dict[str, Any]:
        rom = library.rom(rom_id)
        if rom is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, detail=f"ROM with ID {rom_id} not found")
        return to_detailed(rom)

    return app
