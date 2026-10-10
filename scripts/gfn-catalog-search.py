#!/usr/bin/env python3
"""Fetch/cache the public GeForce NOW apps catalog and filter by title.

Uses unauthenticated GraphQL pagination against games.geforce.com (US/en_US).
Does NOT call authenticated searchQuery or library APIs.

Usage:
  gfn-catalog-search.py [query] [--limit N] [--refresh] [--cache-dir DIR]

Stdout: JSON array of {id, cmsId, title, shortName, appStore, alreadyAdded?}
  cmsId is a *variant* id (Steam preferred), not the top-level GFNDB-style id.
  shortName may be "" — empty is valid for --url-route (do not invent game_gfn_pc).
  alreadyAdded is true when the game+store is already in games.json / gfn desktops
  (rows stay in results; UI labels them — do not hide).

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
# Bump when row shape / cmsId selection changes (invalidates old caches).
CACHE_VERSION = "v3"

# Proven Steam variant (HANDOFF / gfn-play-diablo-iv). Offline fallback only.
DIABLO_IV_FALLBACK = [
    {
        "id": "d32c9410-62cb-45cf-9c53-740bb92d4a2d",
        "cmsId": "102670811",
        "title": "Diablo IV",
        "shortName": "",
        "appStore": "STEAM",
        "boxArt": "",
    }
]

APPS_QUERY = (
    "{{ apps(country:\"{country}\", language:\"{language}\"{after_arg}) "
    "{{ pageInfo {{ hasNextPage endCursor }} "
    "items {{ id cmsId title type "
    "images {{ GAME_BOX_ART }} "
    "variants {{ id shortName appStore }} }} }} }}"
)


def default_cache_dir() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return Path(xdg) / "matt-dance.gfn"
    home = Path.home()
    return home / ".cache" / "matt-dance.gfn"


def default_state_dir() -> Path:
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / "matt-dance.gfn"
    return Path.home() / ".local" / "share" / "matt-dance.gfn"


def default_apps_dir() -> Path:
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / "applications"
    return Path.home() / ".local" / "share" / "applications"


def _desktop_key_value(text: str, key: str) -> str:
    prefix = f"{key}="
    for line in text.splitlines():
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    return ""


def load_already_added(
    state_dir: Path | None = None,
    apps_dir: Path | None = None,
) -> tuple[set[str], set[tuple[str, str]]]:
    """Return (cmsIds, {(parentGameId, APPSTORE)}) already installed locally.

    Match games.json catalog rows and plugin desktops (gfn-<cmsId>.desktop /
    X-GFN-* keys). Used only to label search rows — never to hide them.
    """
    state = state_dir if state_dir is not None else default_state_dir()
    apps = apps_dir if apps_dir is not None else default_apps_dir()
    cms_ids: set[str] = set()
    game_stores: set[tuple[str, str]] = set()

    catalog = state / "games.json"
    if catalog.is_file():
        try:
            raw = json.loads(catalog.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            raw = None
        if isinstance(raw, list):
            for g in raw:
                if not isinstance(g, dict):
                    continue
                cms = str(g.get("cmsId") or "").strip()
                parent = str(g.get("parentGameId") or g.get("id") or "").strip()
                store = str(g.get("appStore") or "").strip().upper()
                if cms:
                    cms_ids.add(cms)
                if parent and store:
                    game_stores.add((parent, store))

    if apps.is_dir():
        for path in apps.glob("gfn-*.desktop"):
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                continue
            cms = _desktop_key_value(text, "X-GFN-CmsId")
            parent = _desktop_key_value(text, "X-GFN-ParentGameId")
            store = _desktop_key_value(text, "X-GFN-AppStore").upper()
            if not cms:
                # Filename convention: gfn-<cmsId>.desktop
                stem = path.stem  # gfn-102670811
                if stem.startswith("gfn-"):
                    maybe = stem[4:]
                    if maybe.isdigit():
                        cms = maybe
            if cms:
                cms_ids.add(cms)
            if parent and store:
                game_stores.add((parent, store))

    return cms_ids, game_stores


def annotate_already_added(
    rows: list[dict[str, str]],
    cms_ids: set[str],
    game_stores: set[tuple[str, str]],
) -> list[dict[str, Any]]:
    """Keep every row; set alreadyAdded for game+store already installed."""
    out: list[dict[str, Any]] = []
    for row in rows:
        cms = str(row.get("cmsId") or "").strip()
        parent = str(row.get("id") or "").strip()
        store = str(row.get("appStore") or "").strip().upper()
        already = bool(cms and cms in cms_ids) or bool(
            parent and store and (parent, store) in game_stores
        )
        annotated: dict[str, Any] = dict(row)
        if already:
            annotated["alreadyAdded"] = True
        out.append(annotated)
    return out


def cache_path(cache_dir: Path) -> Path:
    return cache_dir / f"apps-{COUNTRY}-{LANGUAGE}-{CACHE_VERSION}.json"


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


def _variant_id(variant: dict[str, Any] | None) -> str:
    if not variant:
        return ""
    vid = variant.get("id")
    if vid is None:
        return ""
    return str(vid).strip()


def _is_gfn_cms_id(value: str) -> bool:
    """Launch cmsIds are long numeric strings (e.g. 102670811), not store app stubs."""
    return bool(value) and value.isdigit() and len(value) >= 8


def _store_sort_key(store: str) -> int:
    s = str(store or "").upper()
    order = {"STEAM": 0, "BATTLENET": 1, "EPIC": 2, "GOG": 3, "UBISOFT": 4, "EA": 5}
    return order.get(s, 9)


def _box_art_url(item: dict[str, Any]) -> str:
    images = item.get("images")
    if isinstance(images, dict):
        url = images.get("GAME_BOX_ART") or images.get("KEY_ART") or ""
        return str(url).strip()
    return str(item.get("boxArt") or "").strip()


def launchable_variants(
    variants: list[dict[str, Any]] | None,
    parent_cms_id: str,
) -> list[tuple[str, str, str]]:
    """Return [(cmsId, shortName, appStore), ...] for every launchable store.

    Prefer real long GFN variant ids. If none qualify, fall back to a single
    row using the parent cmsId (older catalog shapes).
    """
    variants = [v for v in (variants or []) if isinstance(v, dict)]
    out: list[tuple[str, str, str]] = []
    for v in sorted(variants, key=lambda x: _store_sort_key(str(x.get("appStore") or ""))):
        vid = _variant_id(v)
        if not _is_gfn_cms_id(vid):
            continue
        out.append((vid, str(v.get("shortName") or "").strip(), str(v.get("appStore") or "")))
    if out:
        return out
    if _is_gfn_cms_id(parent_cms_id):
        store = ""
        short = ""
        if variants:
            preferred = sorted(variants, key=lambda x: _store_sort_key(str(x.get("appStore") or "")))[0]
            store = str(preferred.get("appStore") or "")
            short = str(preferred.get("shortName") or "").strip()
        return [(parent_cms_id, short, store)]
    return []


def normalize_item(item: dict[str, Any]) -> list[dict[str, str]]:
    """Expand one catalog title into one row per launchable store variant."""
    item_id = item.get("id")
    title = item.get("title")
    if not item_id or not title:
        return []
    item_type = item.get("type")
    if item_type is not None and str(item_type).upper() not in ("GAME", ""):
        return []

    parent_cms = item.get("cmsId")
    parent_cms_str = str(parent_cms).strip() if parent_cms is not None else ""
    box_art = _box_art_url(item)
    rows: list[dict[str, str]] = []
    for cms_id, short_name, app_store in launchable_variants(item.get("variants"), parent_cms_str):
        rows.append(
            {
                "id": str(item_id),
                "cmsId": cms_id,
                "title": str(title),
                "shortName": short_name,
                "appStore": app_store,
                "boxArt": box_art,
            }
        )
    return rows


def fetch_catalog() -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    after: str | None = None
    seen_cursors: set[str] = set()
    while True:
        payload = http_get_json(graphql_url(after))
        apps = (payload.get("data") or {}).get("apps") or {}
        page_items = apps.get("items") or []
        for raw in page_items:
            items.extend(normalize_item(raw or {}))
        page_info = apps.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            break
        end_cursor = page_info.get("endCursor")
        if not end_cursor or end_cursor in seen_cursors:
            break
        seen_cursors.add(end_cursor)
        after = str(end_cursor)
    return items


def row_from_cache_dict(raw: dict[str, Any]) -> dict[str, str] | None:
    row = {
        "id": str(raw.get("id") or ""),
        "cmsId": str(raw.get("cmsId") or ""),
        "title": str(raw.get("title") or ""),
        "shortName": str(raw.get("shortName") or ""),
        "appStore": str(raw.get("appStore") or ""),
        "boxArt": str(raw.get("boxArt") or ""),
    }
    if row["id"] and row["cmsId"] and row["title"]:
        return row
    return None


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
        row = row_from_cache_dict(raw)
        if row:
            out.append(row)
    return out or None


def save_cache(path: Path, items: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "fetchedAt": int(time.time()),
        "country": COUNTRY,
        "language": LANGUAGE,
        "version": CACHE_VERSION,
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
                        row = row_from_cache_dict(raw)
                        if row:
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
    cms_ids, game_stores = load_already_added()
    results = annotate_already_added(results, cms_ids, game_stores)
    already_n = sum(1 for r in results if r.get("alreadyAdded"))

    print(
        f"gfn-catalog-search: source={source} catalog={len(items)} "
        f"matches={len(results)} alreadyAdded={already_n}",
        file=sys.stderr,
    )
    # Machine-readable results only on stdout (single JSON value).
    # Already-added rows stay in the list (labeled by the overlay).
    json.dump(results, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
