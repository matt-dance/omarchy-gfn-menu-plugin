#!/usr/bin/env bash
# Rewrite the // gfn-games:start … // gfn-games:end block inside the user's
# omarchy-menu.jsonc from ~/.local/share/matt-dance.gfn/games.json.
# Rows live under gaming.geforce-now.* — store name first so ElideRight
# does not clip Steam / Epic / Battle.net.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/matt-dance.gfn"
CATALOG="${STATE_DIR}/games.json"
TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
BEGIN="// gfn-games:start"
END="// gfn-games:end"

if [[ ! -f "$TARGET" ]]; then
  echo "sync-menu-games: no menu extension at $TARGET (run install-menu-extension.sh first)" >&2
  exit 0
fi

ROWS="$(python3 - "$CATALOG" <<'PY'
import json, os, re, sys

path = sys.argv[1]
games = []
if os.path.isfile(path):
    try:
        games = json.loads(open(path, encoding="utf-8").read())
        if not isinstance(games, list):
            games = []
    except Exception:
        games = []

STORE = {
    "STEAM": "Steam",
    "BATTLENET": "Battle.net",
    "EPIC": "Epic",
    "GOG": "GOG",
    "UPLAY": "Ubisoft",
    "UBISOFT": "Ubisoft",
    "EA": "EA",
}

def slug(title, store, cms):
    base = re.sub(r"[^a-z0-9]+", "-", (title or "").lower()).strip("-")
    store = re.sub(r"[^a-z0-9]+", "-", (store or "").lower()).strip("-")
    cms = re.sub(r"[^a-z0-9]+", "", (cms or "").lower())
    parts = [p for p in (base[:40], store, cms[-8:] if cms else "") if p]
    return "-".join(parts) or "game"

def esc(s):
    return json.dumps(s, ensure_ascii=False)[1:-1]

lines = []
for g in games:
    title = str(g.get("title") or "GeForce NOW Game")
    raw_store = str(g.get("appStore") or "").strip()
    store = STORE.get(raw_store.upper(), raw_store or "GFN")
    cms = str(g.get("cmsId") or "")
    desktop = str(g.get("desktop") or "")
    if not cms or not desktop:
        continue
    key = "gaming.geforce-now." + slug(title, raw_store, cms)
    # Store FIRST in the visible label — menu rows ElideRight and were
    # clipping "… · STEAM" / "Battle.net" off long titles.
    label = f"{store} · {title}"
    desc = "GeForce NOW · GFN"
    aliases = ["gfn", "geforce now", f"{title} gfn", store.lower(), raw_store.lower()]
    obj = {
        "icon": "󰢹",
        "label": label,
        "description": desc,
        "aliases": aliases,
        "action": f"gtk-launch {os.path.basename(desktop)}",
    }
    body = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    lines.append(f'  "{esc(key)}": {body},')

print("\n".join(lines))
PY
)"

python3 - "$TARGET" "$BEGIN" "$END" "$ROWS" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1])
begin, end, rows = sys.argv[2], sys.argv[3], sys.argv[4]
text = target.read_text(encoding="utf-8")

block = begin + ("\n" + rows if rows.strip() else "\n") + "\n  " + end

if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    stripped = pre.rstrip()
    if stripped.endswith("}") and not stripped.endswith("},"):
        pre = stripped + ",\n  "
    new = pre + block + post
else:
    plugin_end = "// END matt-dance.gfn"
    if plugin_end in text:
        new = text.replace(plugin_end, block + "\n  " + plugin_end, 1)
    else:
        idx = text.rfind("}")
        if idx == -1:
            sys.stderr.write("sync-menu-games: cannot find insertion point\n")
            sys.exit(1)
        new = text[:idx] + "  " + block + "\n" + text[idx:]

target.write_text(new, encoding="utf-8")
print(f"sync-menu-games: updated {target}")
PY

if command -v omarchy >/dev/null 2>&1; then
  omarchy menu refresh >/dev/null 2>&1 || true
fi
