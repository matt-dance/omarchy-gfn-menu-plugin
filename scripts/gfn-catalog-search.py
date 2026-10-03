#!/usr/bin/env python3
"""Fetch/cache the public GeForce NOW apps catalog and filter by title.

Uses unauthenticated GraphQL pagination against games.geforce.com (US/en_US).
Does NOT call authenticated searchQuery or library APIs.

Usage:
  gfn-catalog-search.py [query] [--limit N] [--refresh] [--cache-dir DIR]

Stdout: JSON array of {id, cmsId, title, shortName}
  shortName may be "" — launch/writer default to game_gfn_pc.

Exit codes:
  0  success (may be offline Diablo IV fallback; see stderr)
  2  bad arguments
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

# Strip common trademark / punctuation noise so "Diablo IV" matches "Diablo® IV".
_NORMALIZE_RE = re.compile(r"[\u00ae\u2122\u00a9®™©]+")
_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")


def normalize_title(text: str) -> str:
    s = _NORMALIZE_RE.sub(" ", str(text or "").lower())
    s = _NON_ALNUM_RE.sub(" ", s)
    return " ".join(s.split())

ENDPOINT = "https://games.geforce.com/graphql"
COUNTRY = "US"
LANGUAGE = "en_US"
TTL_SECONDS = 6 * 60 * 60  # ~6h
DEFAULT_LIMIT = 40
USER_AGENT = "matt-dance.gfn-catalog-search/0.1 (+Omarchy plugin)"

# Confirmed live catalog snapshot 2026-10-01 (offline fallback only).
DIABLO_IV_FALLBACK = [
    {
        "id": "d32c9410-62cb-45cf-9c53-740bb92d4a2d",
        "cmsId": "101069911",
        "title": "Diablo IV",
        "shortName": "",
    }
]

APPS_QUERY = (
    "{{ apps(country:\"{country}\", language:\"{language}\"{after_arg}) "
    "{{ pageInfo {{ hasNextPage endCursor }} "
    "items {{ id cmsId title type variants {{ shortName appStore }} }} }} }}"
)


def default_cache_dir() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return Path(xdg) / "matt-dance.gfn"
    home = Path.home()
    return home / ".cache" / "matt-dance.gfn"


def cache_path(cache_dir: Path) -> Path:
    return cache_dir / f"apps-{COUNTRY}-{LANGUAGE}.json"


def graphql_url(after: str | None) -> str:
    after_arg = f', after: "{after}"' if after else ""
    query = APPS_QUERY.format(country=COUNTRY, language=LANGUAGE, after_arg=after_arg)
    params = urllib.parse.urlencode({"requestType": "apps", "query": query})
    return f"{ENDPOINT}?{params}"


def http_get_json(url: str, timeout: float = 60.0) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8"))


def pick_short_name(variants: list[dict[str, Any]] | None) -> str:
    if not variants:
        return ""
    # Prefer a non-empty shortName; otherwise keep "" (writer/launch use game_gfn_pc).
    for v in variants:
        sn = (v or {}).get("shortName")
        if isinstance(sn, str) and sn.strip():
            return sn.strip()
    return ""


def normalize_item(item: dict[str, Any]) -> dict[str, str] | None:
    item_id = item.get("id")
    cms_id = item.get("cmsId")
    title = item.get("title")
    if not item_id or cms_id is None or not title:
        return None
    # Prefer GAME rows when type is present; keep unknown types (older payloads).
    item_type = item.get("type")
    if item_type is not None and str(item_type).upper() not in ("GAME", ""):
        return None
    return {
        "id": str(item_id),
        "cmsId": str(cms_id),
        "title": str(title),
        "shortName": pick_short_name(item.get("variants")),
    }


def fetch_catalog() -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    after: str | None = None
    seen_cursors: set[str] = set()
    while True:
        payload = http_get_json(graphql_url(after))
        apps = (payload.get("data") or {}).get("apps") or {}
        page_items = apps.get("items") or []
        for raw in page_items:
            row = normalize_item(raw or {})
            if row:
                items.append(row)
        page_info = apps.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            break
        end_cursor = page_info.get("endCursor")
        if not end_cursor or end_cursor in seen_cursors:
            break
        seen_cursors.add(end_cursor)
        after = str(end_cursor)
    return items


def load_cache(path: Path) -> list[dict[str, str]] | None:
    if not path.is_file():
        return None
    age = time.time() - path.stat().st_mtime
    if age > TTL_SECONDS:
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list) or not items:
        return None
    out: list[dict[str, str]] = []
    for raw in items:
        if not isinstance(raw, dict):
            continue
        row = {
            "id": str(raw.get("id") or ""),
            "cmsId": str(raw.get("cmsId") or ""),
            "title": str(raw.get("title") or ""),
            "shortName": str(raw.get("shortName") or ""),
        }
        if row["id"] and row["cmsId"] and row["title"]:
            out.append(row)
    return out or None


def save_cache(path: Path, items: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "fetchedAt": int(time.time()),
        "country": COUNTRY,
        "language": LANGUAGE,
        "count": len(items),
        "items": items,
    }
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp.replace(path)


def title_matches(title: str, query: str) -> bool:
    """Case-insensitive match; ignores ®/™ and punctuation between tokens."""
    q = normalize_title(query)
    if not q:
        return True
    hay = normalize_title(title)
    if q in hay:
        return True
    # Token AND: every query token appears in the title (order preserved loosely).
    q_tokens = q.split()
    hay_tokens = hay.split()
    if not q_tokens:
        return True
    i = 0
    for token in hay_tokens:
        if i < len(q_tokens) and token == q_tokens[i]:
            i += 1
    return i == len(q_tokens)


def filter_items(items: list[dict[str, str]], query: str, limit: int) -> list[dict[str, str]]:
    q = query.strip()
    # Empty query → no rows (overlay prompts the user to type a title).
    if not q:
        return []
    matched = [row for row in items if title_matches(row["title"], q)]
    return matched[:limit]


def resolve_catalog(cache_dir: Path, refresh: bool) -> tuple[list[dict[str, str]], str]:
    path = cache_path(cache_dir)
    if not refresh:
        cached = load_cache(path)
        if cached is not None:
            return cached, "cache"

    try:
        items = fetch_catalog()
        if not items:
            raise RuntimeError("empty catalog response")
        save_cache(path, items)
        return items, "network"
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError, RuntimeError) as exc:
        # Stale cache is better than nothing when refresh/network fails.
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                items = data.get("items") if isinstance(data, dict) else None
                if isinstance(items, list) and items:
                    print(f"gfn-catalog-search: network failed ({exc}); using stale cache", file=sys.stderr)
                    out: list[dict[str, str]] = []
                    for raw in items:
                        if not isinstance(raw, dict):
                            continue
                        row = {
                            "id": str(raw.get("id") or ""),
                            "cmsId": str(raw.get("cmsId") or ""),
                            "title": str(raw.get("title") or ""),
                            "shortName": str(raw.get("shortName") or ""),
                        }
                        if row["id"] and row["cmsId"] and row["title"]:
                            out.append(row)
                    if out:
                        return out, "stale-cache"
            except (OSError, json.JSONDecodeError):
                pass
        print(f"gfn-catalog-search: network/cache failed ({exc}); Diablo IV offline fallback", file=sys.stderr)
        return DIABLO_IV_FALLBACK, "fallback"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Search cached GFN public catalog by title.")
    parser.add_argument("query", nargs="?", default="", help="Case-insensitive title substring")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help=f"Max rows (default {DEFAULT_LIMIT})")
    parser.add_argument("--refresh", action="store_true", help="Bypass TTL and refetch catalog")
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=None,
        help="Cache directory (default: $XDG_CACHE_HOME/matt-dance.gfn)",
    )
    args = parser.parse_args(argv)

    if args.limit < 1:
        print("--limit must be >= 1", file=sys.stderr)
        return 2

    cache_dir = args.cache_dir if args.cache_dir is not None else default_cache_dir()
    items, source = resolve_catalog(cache_dir, refresh=args.refresh)
    results = filter_items(items, args.query, args.limit)

    print(
        f"gfn-catalog-search: source={source} catalog={len(items)} matches={len(results)}",
        file=sys.stderr,
    )
    # Machine-readable results only on stdout (single JSON value).
    json.dump(results, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
