#!/usr/bin/env bash
# Rewrite the // gfn-games:start … // gfn-games:end block inside the user's
# omarchy-menu.jsonc from ~/.local/share/matt-dance.gfn/games.json.
# Safe: only replaces that marked region; leaves the rest of the file alone.

set -euo pipefail

PLUGIN_ID="matt-dance.gfn"
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

def slug(title, store, cms):
    base = re.sub(r"[^a-z0-9]+", "-", (title or "").lower()).strip("-")
    store = re.sub(r"[^a-z0-9]+", "-", (store or "").lower()).strip("-")
    cms = re.sub(r"[^a-z0-9]+", "", (cms or "").lower())
    parts = [p for p in (base[:40], store, cms[-8:] if cms else "") if p]
    return "-".join(parts) or "game"

lines = []
for g in games:
    title = str(g.get("title") or "GeForce NOW Game")
    store = str(g.get("appStore") or "")
    cms = str(g.get("cmsId") or "")
    desktop = str(g.get("desktop") or "")
    if not cms or not desktop:
        continue
    key = "games.gfn-" + slug(title, store, cms)
    label = title if not store else f"{title} ({store})"
    # Escape JSON string values.
    def esc(s):
        return json.dumps(s, ensure_ascii=False)[1:-1]
    action = f"gtk-launch {os.path.basename(desktop)}"
    desc = store if store else "GeForce NOW"
    lines.append(
        f'  "{esc(key)}": {{"icon":"","label":"{esc(label)}","description":"{esc(desc)}","action":"{esc(action)}"}},'
    )
print("\n".join(lines))
PY
)"

BLOCK="${BEGIN}
${ROWS}
  ${END}"

python3 - "$TARGET" "$BEGIN" "$END" "$BLOCK" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1])
begin, end, block = sys.argv[2], sys.argv[3], sys.argv[4]
text = target.read_text(encoding="utf-8")
if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
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
