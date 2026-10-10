#!/usr/bin/env bash
# Remove one or more GeForce NOW Menu games: desktop, icon, catalog, menu sync.
# Intended for: omarchy-launch-floating-terminal-with-presentation …
# Matt UX: gum multi-select → one confirm → remove all selected.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/matt-dance.gfn-omarchy"
CATALOG="${STATE_DIR}/games.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$CATALOG" ]]; then
  echo "No GFN games catalog at $CATALOG" >&2
  exit 1
fi

mapfile -t CHOICES < <(python3 - "$CATALOG" <<'PY'
import json, sys
from pathlib import Path
games = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(games, list) or not games:
    sys.exit(0)
STORE = {
    "STEAM": "Steam",
    "BATTLENET": "Battle.net",
    "EPIC": "Epic",
    "GOG": "GOG",
    "UPLAY": "Ubisoft",
    "UBISOFT": "Ubisoft",
    "EA": "EA",
}
for g in sorted(games, key=lambda x: (str(x.get("title") or "").lower(), str(x.get("appStore") or ""))):
    title = str(g.get("title") or "Game")
    store = STORE.get(str(g.get("appStore") or "").upper(), str(g.get("appStore") or "GFN"))
    cms = str(g.get("cmsId") or "")
    # Store first (readable); cmsId in brackets for reliable parse after gum.
    print(f"{store} · {title} [{cms}]")
PY
)

if [[ ${#CHOICES[@]} -eq 0 ]]; then
  echo "No GeForce NOW games to remove."
  exit 0
fi

PICKS="$(printf '%s\n' "${CHOICES[@]}" | gum choose --no-limit --header "Remove which GeForce NOW game(s)? (space to select, enter to confirm)" --height 15)" || {
  echo "Cancelled."
  exit 0
}

if [[ -z "${PICKS//[$'\t\n\r ']/}" ]]; then
  echo "Cancelled."
  exit 0
fi

mapfile -t SELECTED < <(printf '%s\n' "$PICKS")
# Drop empty lines from gum output.
CLEAN=()
for line in "${SELECTED[@]}"; do
  [[ -n "${line//[$'\t\r ']/}" ]] && CLEAN+=("$line")
done
SELECTED=("${CLEAN[@]}")

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "Cancelled."
  exit 0
fi

COUNT="${#SELECTED[@]}"
if [[ "$COUNT" -eq 1 ]]; then
  LABEL_PREVIEW="${SELECTED[0]% \[*}"
  CONFIRM_MSG="Remove “${LABEL_PREVIEW}” from the GeForce NOW menu and Apps?"
else
  CONFIRM_MSG="Remove ${COUNT} selected games from the GeForce NOW menu and Apps?"
fi

if ! gum confirm "$CONFIRM_MSG"; then
  echo "Cancelled."
  exit 0
fi

REMOVED_LABELS=()
FAILED=0
for PICK in "${SELECTED[@]}"; do
  CMS_ID="$(printf '%s' "$PICK" | sed -n 's/.*\[\([0-9][0-9]*\)\]$/\1/p')"
  if [[ -z "$CMS_ID" ]]; then
    echo "Could not parse selection: $PICK" >&2
    FAILED=1
    continue
  fi
  LABEL="${PICK% \[*}"

  if ! python3 - "$CATALOG" "$CMS_ID" <<'PY'
import json, os, sys
from pathlib import Path

catalog = Path(sys.argv[1])
cms = sys.argv[2]
games = json.loads(catalog.read_text(encoding="utf-8"))
keep = []
removed = None
for g in games:
    if str(g.get("cmsId") or "") == cms:
        removed = g
    else:
        keep.append(g)
if removed is None:
    print(f"No catalog row for cmsId={cms}", file=sys.stderr)
    sys.exit(1)
catalog.write_text(json.dumps(keep, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

desktop = Path(str(removed.get("desktop") or ""))
icon = Path(str(removed.get("icon") or ""))
apps = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "applications"
icons = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "icons" / "gfn"
cand_desktop = apps / f"gfn-{cms}.desktop"
cand_icon = icons / f"gfn-{cms}.png"

def desktop_kv(text: str, key: str) -> str:
    prefix = f"{key}="
    for line in text.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].strip()
    return ""

# Remove catalog path + canonical cmsId desktop…
to_remove = {p for p in (desktop, cand_desktop) if p.is_file()}
# …and any other plugin-owned gfn-*.desktop that still carries this cmsId
# (e.g. legacy gfn-<parentGameId>.desktop). Do NOT touch proven
# gfn-diablo-iv.desktop (no X-Omarchy-Plugin / X-GFN-CmsId).
if apps.is_dir():
    for path in apps.glob("gfn-*.desktop"):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if desktop_kv(text, "X-Omarchy-Plugin") != "matt-dance.gfn-omarchy":
            continue
        if desktop_kv(text, "X-GFN-CmsId") == cms or path.name == f"gfn-{cms}.desktop":
            to_remove.add(path)

for path in sorted(to_remove):
    path.unlink()
    print(f"removed {path}")

for path in (icon, cand_icon):
    if path.is_file() and str(path).startswith(str(icons)):
        path.unlink()
        print(f"removed {path}")
print(f"removed catalog row cmsId={cms}")
PY
  then
    FAILED=1
    continue
  fi
  REMOVED_LABELS+=("$LABEL")
done

if [[ -x "${SCRIPT_DIR}/sync-menu-games.sh" ]]; then
  "${SCRIPT_DIR}/sync-menu-games.sh"
fi

if [[ ${#REMOVED_LABELS[@]} -eq 0 ]]; then
  echo "Nothing removed." >&2
  exit 1
fi

if [[ ${#REMOVED_LABELS[@]} -eq 1 ]]; then
  SUMMARY="${REMOVED_LABELS[0]}"
  echo "Done. “${SUMMARY}” removed from GeForce NOW Menu / Apps."
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "GeForce NOW Menu" "Removed GFN game" "$SUMMARY" || true
  fi
else
  SUMMARY="${#REMOVED_LABELS[@]} games"
  echo "Done. Removed ${#REMOVED_LABELS[@]} GeForce NOW games:"
  for L in "${REMOVED_LABELS[@]}"; do
    echo "  - $L"
  done
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "GeForce NOW Menu" "Removed ${#REMOVED_LABELS[@]} GFN games" "$(printf '%s\n' "${REMOVED_LABELS[@]}")" || true
  fi
fi

# Keep the floating terminal readable for a moment when launched from the menu.
if [[ -t 0 ]] && command -v gum >/dev/null 2>&1; then
  gum input --placeholder "Press Enter to close" --prompt "" >/dev/null 2>&1 || true
fi

exit "$FAILED"
