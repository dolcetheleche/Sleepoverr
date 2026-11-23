"""Fixture loading and expansion into RomM-shaped response objects.

The fixture files are kept compact and human-editable (only the fields that vary per
ROM/platform). Everything else a real RomM response carries is filled in here with the
same null/empty/false defaults RomM uses, so the JSON the mock serves matches RomM's
PlatformSchema / SimpleRomSchema / DetailedRomSchema / RomUserSchema shapes.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(os.environ.get("MOCK_ROMM_FIXTURES_DIR", Path(__file__).resolve().parent.parent / "fixtures"))

# Mirrors RomM's RomUserStatus enum (backend/models/rom.py).
ROM_USER_STATUSES = ("incomplete", "finished", "completed_100", "retired", "never_playing")

# The mock pretends to be a RomM instance with exactly one user.
MOCK_USER_ID = 1


def parse_dt(value: str) -> datetime:
    """Parse an ISO-8601 timestamp, treating naive values as UTC."""
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def _strip_tags(name: str) -> str:
    # "Super Metroid (Japan, USA) (En,Ja)" -> "Super Metroid"
    return re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", name).strip()


def _slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _tags(fs_name_no_ext: str) -> list[str]:
    return re.findall(r"\(([^)]*)\)", fs_name_no_ext)


_REGION_WORDS = {"USA", "Europe", "Japan", "World"}


def expand_platform(raw: dict[str, Any], roms: list[dict[str, Any]]) -> dict[str, Any]:
    own = [r for r in roms if r["platform_id"] == raw["id"]]
    return {
        "id": raw["id"],
        "slug": raw["slug"],
        "fs_slug": raw["fs_slug"],
        "rom_count": len(own),
        "name": raw["name"],
        "igdb_slug": raw.get("igdb_slug"),
        "moby_slug": None,
        "hltb_slug": None,
        "libretro_slug": None,
        "custom_name": None,
        "display_name": raw.get("display_name") or raw["name"],
        "description": None,
        "igdb_id": raw.get("igdb_id"),
        "sgdb_id": None,
        "moby_id": None,
        "launchbox_id": None,
        "ss_id": None,
        "ra_id": None,
        "hasheous_id": None,
        "tgdb_id": None,
        "flashpoint_id": None,
        "category": raw.get("category"),
        "generation": raw.get("generation"),
        "first_release_year": None,
        "family_name": raw.get("family_name"),
        "family_slug": raw.get("family_slug"),
        "url": None,
        "url_logo": None,
        "aspect_ratio": "2 / 3",
        "firmware": [],
        "created_at": raw["created_at"],
        "updated_at": raw["updated_at"],
        "fs_size_bytes": sum(r["fs_size_bytes"] for r in own),
        "is_unidentified": raw.get("igdb_id") is None,
        "is_identified": raw.get("igdb_id") is not None,
        "missing_from_fs": False,
    }


def expand_rom_user(rom_id: int, raw: dict[str, Any] | None, rom_updated_at: str) -> dict[str, Any]:
    if raw is None:
        # RomM returns this exact placeholder (rom_user_schema_factory: ids -1, everything
        # unset) when the user has never touched the ROM - a sync must handle it.
        return {
            "id": -1,
            "user_id": -1,
            "rom_id": -1,
            "created_at": rom_updated_at,
            "updated_at": rom_updated_at,
            "last_played": None,
            "is_main_sibling": False,
            "backlogged": False,
            "now_playing": False,
            "hidden": False,
            "rating": 0,
            "difficulty": 0,
            "completion": 0,
            "status": None,
            "pinned_media": None,
            "user__username": "",
        }
    return {
        "id": 1000 + rom_id,
        "user_id": MOCK_USER_ID,
        "rom_id": rom_id,
        "created_at": raw.get("created_at", rom_updated_at),
        "updated_at": raw.get("updated_at", rom_updated_at),
        "last_played": raw.get("last_played"),
        "is_main_sibling": raw.get("is_main_sibling", False),
        "backlogged": raw.get("backlogged", False),
        "now_playing": raw.get("now_playing", False),
        "hidden": raw.get("hidden", False),
        "rating": raw.get("rating", 0),
        "difficulty": raw.get("difficulty", 0),
        "completion": raw.get("completion", 0),
        "status": raw.get("status"),
        "pinned_media": None,
        "user__username": os.environ.get("MOCK_ROMM_USER", "admin"),
    }


def expand_rom(raw: dict[str, Any], platform: dict[str, Any]) -> dict[str, Any]:
    fs_name: str = raw["fs_name"]
    fs_name_no_ext, _, fs_extension = fs_name.rpartition(".")
    unidentified = bool(raw.get("is_unidentified", False))
    name = None if unidentified else raw.get("name") or _strip_tags(fs_name_no_ext)
    tags = _tags(fs_name_no_ext)
    regions = [w.strip() for t in tags for w in t.split(",") if w.strip() in _REGION_WORDS]
    revision = next((t.removeprefix("Rev ").strip() for t in tags if t.startswith("Rev ")), None)
    fs_path = f"roms/{platform['fs_slug']}"
    return {
        "id": raw["id"],
        "igdb_id": raw.get("igdb_id"),
        "sgdb_id": None,
        "moby_id": None,
        "ss_id": None,
        "ra_id": None,
        "launchbox_id": None,
        "hasheous_id": None,
        "tgdb_id": None,
        "flashpoint_id": None,
        "hltb_id": None,
        "gamelist_id": None,
        "platform_id": platform["id"],
        "platform_slug": platform["slug"],
        "platform_fs_slug": platform["fs_slug"],
        "platform_custom_name": None,
        "platform_display_name": platform.get("display_name") or platform["name"],
        "fs_name": fs_name,
        "fs_name_no_tags": _strip_tags(fs_name_no_ext),
        "fs_name_no_ext": fs_name_no_ext,
        "fs_extension": fs_extension,
        "fs_path": fs_path,
        "fs_size_bytes": raw["fs_size_bytes"],
        "name": name,
        "slug": None if name is None else _slugify(name),
        "summary": None,
        "alternative_names": [],
        "youtube_video_id": None,
        "metadatum": {
            "rom_id": raw["id"],
            "genres": [],
            "franchises": [],
            "collections": [],
            "companies": [],
            "game_modes": [],
            "age_ratings": [],
            "player_count": "",
            "first_release_date": None,
            "average_rating": None,
        },
        "igdb_metadata": None,
        "moby_metadata": None,
        "ss_metadata": None,
        "launchbox_metadata": None,
        "hasheous_metadata": None,
        "flashpoint_metadata": None,
        "hltb_metadata": None,
        "gamelist_metadata": None,
        "path_cover_small": None,
        "path_cover_large": None,
        "url_cover": None,
        "has_manual": False,
        "path_manual": None,
        "url_manual": None,
        "is_identifying": False,
        "is_unidentified": unidentified,
        "is_identified": not unidentified,
        "revision": revision,
        "regions": regions,
        "languages": [],
        "tags": [t for t in tags if t not in regions and not t.startswith("Rev ")],
        "crc_hash": None,
        "md5_hash": None,
        "sha1_hash": None,
        "has_simple_single_file": True,
        "has_nested_single_file": False,
        "has_multiple_files": False,
        "files": [],
        "full_path": f"{fs_path}/{fs_name}",
        "created_at": raw["created_at"],
        "updated_at": raw["updated_at"],
        "missing_from_fs": False,
        "has_notes": False,
        "merged_screenshots": [],
        # Older RomM OpenAPI specs call this `siblings`; current RomM serialises `sibling_roms`.
        # Emit both so a client written against either works.
        "siblings": [],
        "sibling_roms": [],
        # Play data lives ONLY here, never at the top level (same as RomM).
        "rom_user": expand_rom_user(raw["id"], raw.get("rom_user"), raw["updated_at"]),
    }


def to_detailed(rom: dict[str, Any]) -> dict[str, Any]:
    return {
        **rom,
        "user_saves": [],
        "user_states": [],
        "user_screenshots": [],
        "user_collections": [],
        "all_user_notes": [],
    }


@dataclass
class Library:
    platforms: list[dict[str, Any]]
    roms: list[dict[str, Any]]
    source: Path

    def rom(self, rom_id: int) -> dict[str, Any] | None:
        return next((r for r in self.roms if r["id"] == rom_id), None)


def load_library(fixtures_dir: Path = FIXTURES_DIR, prefer_resolved: bool = True) -> Library:
    """Load fixtures, preferring roms.resolved.json (written by resolve_igdb_ids.py) if present."""
    resolved = fixtures_dir / "roms.resolved.json"
    roms_path = resolved if prefer_resolved and resolved.exists() else fixtures_dir / "roms.json"
    raw_platforms = json.loads((fixtures_dir / "platforms.json").read_text(encoding="utf-8"))
    raw_roms = json.loads(roms_path.read_text(encoding="utf-8"))
    by_id = {p["id"]: p for p in raw_platforms}
    platforms = [expand_platform(p, raw_roms) for p in raw_platforms]
    roms = [expand_rom(r, by_id[r["platform_id"]]) for r in raw_roms]
    return Library(platforms=platforms, roms=roms, source=roms_path)
