#!/usr/bin/env bash
# Remove one or more GeForce NOW Menu games: desktop, icon, catalog, menu sync.
# Intended for: omarchy-launch-floating-terminal-with-presentation …
# Multi-select via gum choose --no-limit; one confirm for the whole batch.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/matt-dance.gfn"
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

# Space/tab multi-select; Enter confirms the selection set.
mapfile -t PICKS < <(
  printf '%s\n' "${CHOICES[@]}" | gum choose --no-limit \
    --header "Remove which GeForce NOW game(s)? (space to toggle, enter to confirm)" \
    --height 15
) || {
  echo "Cancelled."
  exit 0
}

if [[ ${#PICKS[@]} -eq 0 ]]; then
  echo "Cancelled."
  exit 0
fi

CMS_IDS=()
LABELS=()
for PICK in "${PICKS[@]}"; do
  CMS_ID="$(printf '%s' "$PICK" | sed -n 's/.*\[\([0-9][0-9]*\)\]$/\1/p')"
  if [[ -z "$CMS_ID" ]]; then
    echo "Could not parse selection: $PICK" >&2
    exit 1
  fi
  CMS_IDS+=("$CMS_ID")
  LABELS+=("${PICK% \[*}")
done

CONFIRM_BODY="$(printf '%s\n' "${LABELS[@]}")"
COUNT="${#CMS_IDS[@]}"
if [[ "$COUNT" -eq 1 ]]; then
  CONFIRM_Q="Remove “${LABELS[0]}” from the GeForce NOW menu and Apps?"
else
  CONFIRM_Q="Remove ${COUNT} games from the GeForce NOW menu and Apps?"
fi

if ! gum confirm "$CONFIRM_Q"$'\n\n'"$CONFIRM_BODY"; then
  echo "Cancelled."
  exit 0
fi

# Pass all cmsIds to one Python pass so catalog write is atomic.
python3 - "$CATALOG" "${CMS_IDS[@]}" <<'PY'
import json, os, sys
from pathlib import Path

catalog = Path(sys.argv[1])
want = {str(x) for x in sys.argv[2:]}
games = json.loads(catalog.read_text(encoding="utf-8"))
keep = []
removed = []
for g in games:
    cms = str(g.get("cmsId") or "")
    if cms in want:
        removed.append(g)
    else:
        keep.append(g)
if not removed:
    print("No catalog rows matched the selection", file=sys.stderr)
    sys.exit(1)
catalog.write_text(json.dumps(keep, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

apps = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "applications"
icons = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "icons" / "gfn"
for rem in removed:
    cms = str(rem.get("cmsId") or "")
    desktop = Path(str(rem.get("desktop") or ""))
    icon = Path(str(rem.get("icon") or ""))
    cand_desktop = apps / f"gfn-{cms}.desktop"
    cand_icon = icons / f"gfn-{cms}.png"
    for path in (desktop, cand_desktop):
        if path.is_file():
            path.unlink()
            print(f"removed {path}")
    for path in (icon, cand_icon):
        if path.is_file() and str(path).startswith(str(icons)):
            path.unlink()
            print(f"removed {path}")
    print(f"removed catalog row cmsId={cms}")
PY

if [[ -x "${SCRIPT_DIR}/sync-menu-games.sh" ]]; then
  "${SCRIPT_DIR}/sync-menu-games.sh"
fi

if [[ "$COUNT" -eq 1 ]]; then
  DONE_MSG="Done. “${LABELS[0]}” removed from GeForce NOW Menu / Apps."
  NOTIFY_BODY="${LABELS[0]}"
else
  DONE_MSG="Done. ${COUNT} games removed from GeForce NOW Menu / Apps."
  NOTIFY_BODY="$(printf '%s\n' "${LABELS[@]}")"
fi
echo "$DONE_MSG"
if command -v notify-send >/dev/null 2>&1; then
  notify-send -a "GeForce NOW Menu" "Removed GFN game(s)" "$NOTIFY_BODY" || true
fi
# Keep the floating terminal readable for a moment when launched from the menu.
if [[ -t 0 ]] && command -v gum >/dev/null 2>&1; then
  gum input --placeholder "Press Enter to close" --prompt "" >/dev/null 2>&1 || true
fi
