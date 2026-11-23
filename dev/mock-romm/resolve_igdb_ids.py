#!/usr/bin/env python3
"""OPTIONAL: fill real IGDB game ids into the mock's ROM fixtures.

The committed fixtures deliberately have ``igdb_id: null`` everywhere (ids are never
invented from memory). Run this on a machine with internet access and your own IGDB
(Twitch) API credentials to look every identified fixture title up on IGDB and write the
best match's id into ``fixtures/roms.resolved.json`` (gitignored). The mock server prefers
that file over ``roms.json`` when it exists; delete it to go back to the committed data.

    export IGDB_CLIENT_ID=...  IGDB_CLIENT_SECRET=...
    python dev/mock-romm/resolve_igdb_ids.py            # identified ROMs only
    python dev/mock-romm/resolve_igdb_ids.py --dry-run  # print matches, write nothing

ROMs marked ``is_unidentified`` are skipped (they exist to exercise the "unmatched" path)
unless ``--include-unidentified`` is given.

NOTE: this script was written in a sandbox with no network access to IGDB, so it has only
been tested against mocked HTTP responses (tests/test_resolve_igdb_ids.py, using respx).
Check the printed matches before relying on them.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

import httpx

TWITCH_TOKEN_URL = "https://id.twitch.tv/oauth2/token"
IGDB_GAMES_URL = "https://api.igdb.com/v4/games"
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"
REQUEST_INTERVAL = 0.3  # IGDB allows 4 requests/second


def get_access_token(client: httpx.Client, client_id: str, client_secret: str) -> str:
    resp = client.post(
        TWITCH_TOKEN_URL,
        params={"client_id": client_id, "client_secret": client_secret, "grant_type": "client_credentials"},
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def title_for(rom: dict[str, Any]) -> str:
    if rom.get("name"):
        return rom["name"]
    stem = rom["fs_name"].rsplit(".", 1)[0]
    return re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", stem).strip()


def _normalise(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def best_match(title: str, results: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Prefer an exact (normalised) name match, else IGDB's top-ranked search result."""
    if not results:
        return None
    wanted = _normalise(title)
    for r in results:
        if _normalise(r.get("name", "")) == wanted:
            return r
    return results[0]


def search_game(
    client: httpx.Client, client_id: str, token: str, title: str, platform_igdb_id: int | None
) -> list[dict[str, Any]]:
    escaped = title.replace("\\", "\\\\").replace('"', '\\"')
    query = f'search "{escaped}"; fields id,name;'
    if platform_igdb_id is not None:
        query += f" where platforms = ({platform_igdb_id});"
    query += " limit 10;"
    resp = client.post(
        IGDB_GAMES_URL,
        content=query,
        headers={"Client-ID": client_id, "Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    resp.raise_for_status()
    return resp.json()


def resolve(
    client: httpx.Client,
    client_id: str,
    client_secret: str,
    fixtures_dir: Path = FIXTURES_DIR,
    include_unidentified: bool = False,
    sleep: float = REQUEST_INTERVAL,
) -> list[dict[str, Any]]:
    roms = json.loads((fixtures_dir / "roms.json").read_text(encoding="utf-8"))
    platforms = {p["id"]: p for p in json.loads((fixtures_dir / "platforms.json").read_text(encoding="utf-8"))}
    token = get_access_token(client, client_id, client_secret)
    for rom in roms:
        if rom.get("is_unidentified") and not include_unidentified:
            continue
        title = title_for(rom)
        results = search_game(client, client_id, token, title, platforms[rom["platform_id"]].get("igdb_id"))
        match = best_match(title, results)
        rom["igdb_id"] = match["id"] if match else None
        shown = f"{match['id']} {match['name']!r}" if match else "NO MATCH"
        print(f"  #{rom['id']:>3} {title!r:55} -> {shown}")
        if sleep:
            time.sleep(sleep)
    return roms


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--include-unidentified", action="store_true", help="also resolve is_unidentified ROMs")
    parser.add_argument("--dry-run", action="store_true", help="print matches without writing roms.resolved.json")
    parser.add_argument("--fixtures-dir", type=Path, default=FIXTURES_DIR)
    args = parser.parse_args(argv)

    client_id = os.environ.get("IGDB_CLIENT_ID")
    client_secret = os.environ.get("IGDB_CLIENT_SECRET")
    if not client_id or not client_secret:
        print("IGDB_CLIENT_ID and IGDB_CLIENT_SECRET must be set (Twitch developer app credentials).", file=sys.stderr)
        return 2

    with httpx.Client(timeout=20) as client:
        roms = resolve(client, client_id, client_secret, args.fixtures_dir, args.include_unidentified)

    if args.dry_run:
        print("Dry run: nothing written.")
        return 0
    out = args.fixtures_dir / "roms.resolved.json"
    out.write_text(json.dumps(roms, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {out} - restart mock-romm to pick it up (delete the file to revert).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
