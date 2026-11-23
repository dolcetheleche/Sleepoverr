#!/usr/bin/env python3
"""Create a fake RomM library of tiny placeholder files matching the mock-romm fixtures.

Every file contains only the text "placeholder" - these are NOT ROMs and no emulator will
run them. They exist so a real RomM container (the `real-romm` compose profile) has a
library to scan whose filenames match the mock's fixtures.

Layout is RomM's recommended "Structure A" (docs.romm.app -> Getting Started -> Folder
Structure):  <out>/roms/<platform fs_slug>/<file>,  e.g. dev/data/library/roms/snes/...

Folder names are the fixtures' `fs_slug`s (nes, snes, genesis, gba, psx, n64), which are
RomM's canonical platform slugs (UniversalPlatformSlug in RomM's source).

Idempotent: existing files are left untouched; run it as often as you like.

    python3 dev/seed/make_placeholder_roms.py [--out dev/data/library]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEV_DIR = Path(__file__).resolve().parent.parent
FIXTURES_DIR = DEV_DIR / "mock-romm" / "fixtures"
DEFAULT_OUT = DEV_DIR / "data" / "library"
CONTENT = b"placeholder\n"


def build(out: Path, fixtures_dir: Path = FIXTURES_DIR) -> tuple[int, int]:
    """Create missing placeholder files. Returns (created, already_present)."""
    platforms = {p["id"]: p for p in json.loads((fixtures_dir / "platforms.json").read_text(encoding="utf-8"))}
    roms = json.loads((fixtures_dir / "roms.json").read_text(encoding="utf-8"))
    created = existing = 0
    for rom in roms:
        folder = out / "roms" / platforms[rom["platform_id"]]["fs_slug"]
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / rom["fs_name"]
        if target.exists():
            existing += 1
            continue
        target.write_bytes(CONTENT)
        created += 1
    # Optional BIOS root of Structure A; RomM is fine with it empty.
    (out / "bios").mkdir(parents=True, exist_ok=True)
    return created, existing


def summary(out: Path) -> str:
    lines = [f"{out}/"]
    roms_dir = out / "roms"
    for platform_dir in sorted(p for p in roms_dir.iterdir() if p.is_dir()):
        files = sorted(platform_dir.iterdir())
        lines.append(f"  roms/{platform_dir.name}/  ({len(files)} files)")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"library root (default: {DEFAULT_OUT})")
    args = parser.parse_args(argv)
    created, existing = build(args.out)
    print(f"Placeholder library: {created} created, {existing} already present.")
    print(summary(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
