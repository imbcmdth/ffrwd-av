"""Writes pins.json for a directory of ffrwd-av archives.

    python scripts/pins.py <archive dir> <release URL prefix> [--partial]

Prints a JSON object mapping each platform to its archive's URL, sha256 and
size in bytes. Every platform must be present unless --partial is given.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

PLATFORMS = (
    "manylinux-x86_64",
    "manylinux-aarch64",
    "musllinux-x86_64",
    "musllinux-aarch64",
    "macos-aarch64",
    "windows-x86_64",
    "windows-aarch64",
)

PREFIX = "ffrwd-av-"
SUFFIX = ".tar.gz"


def split_name(name: str) -> tuple[str, str] | None:
    """Returns (tag, platform) for an archive name, or None."""
    if not (name.startswith(PREFIX) and name.endswith(SUFFIX)):
        return None
    stem = name[len(PREFIX) : -len(SUFFIX)]
    for platform in PLATFORMS:
        if stem.endswith("-" + platform):
            tag = stem[: -len(platform) - 1]
            if tag:
                return tag, platform
    return None


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pins(directory: pathlib.Path, url_prefix: str, partial: bool) -> dict[str, dict[str, object]]:
    found: dict[str, dict[str, object]] = {}
    tags: set[str] = set()
    for path in sorted(directory.glob(PREFIX + "*" + SUFFIX)):
        parsed = split_name(path.name)
        if parsed is None:
            raise SystemExit(f"{path.name}: not an ffrwd-av-<tag>-<platform>{SUFFIX} name")
        tag, platform = parsed
        tags.add(tag)
        found[platform] = {
            "url": url_prefix.rstrip("/") + "/" + path.name,
            "sha256": sha256(path),
            "bytes": path.stat().st_size,
        }
    if len(tags) > 1:
        raise SystemExit(f"archives from more than one tag: {', '.join(sorted(tags))}")
    missing = [p for p in PLATFORMS if p not in found]
    if not found:
        raise SystemExit(f"no archives in {directory}")
    if missing and not partial:
        raise SystemExit(f"no archive for {', '.join(missing)}")
    return {p: found[p] for p in PLATFORMS if p in found}


def main() -> None:
    parser = argparse.ArgumentParser(description="Write pins.json for ffrwd-av archives.")
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("url_prefix", help="the release's download URL, without the file name")
    parser.add_argument("--partial", action="store_true", help="allow platforms to be missing")
    args = parser.parse_args()
    json.dump(pins(args.directory, args.url_prefix, args.partial), sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
