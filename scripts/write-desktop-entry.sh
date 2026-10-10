#!/usr/bin/env bash
# Write a GeForce NOW title as a desktop application entry so it appears under
# Omarchy Apps / Super+Space search (same idea as RetroArch Game Launcher).
#
# Usage:
#   write-desktop-entry.sh --cms-id <cmsId> --parent-game-id <uuid> \
#     --title <display-name> [--short-name <slug>] [--app-store <STORE>] \
#     [--box-art-url <url>] [--force]
#
# --short-name may be empty (proven Diablo IV launcher uses empty shortName).
# Do not invent game_gfn_pc.
#
# Output path (one file per store variant):
#   ~/.local/share/applications/gfn-<cmsId>.desktop
# Icon (when --box-art-url is set):
#   ~/.local/share/icons/gfn/gfn-<cmsId>.png

set -euo pipefail

CMS_ID=""
PARENT_GAME_ID=""
SHORT_NAME=""
GAME_TITLE=""
APP_STORE=""
BOX_ART_URL=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cms-id)
      CMS_ID="${2:-}"
      shift 2
      ;;
    --parent-game-id)
      PARENT_GAME_ID="${2:-}"
      shift 2
      ;;
    --short-name)
      SHORT_NAME="${2:-}"
      shift 2
      ;;
    --title)
      GAME_TITLE="${2:-}"
      shift 2
      ;;
    --app-store)
      APP_STORE="${2:-}"
      shift 2
      ;;
    --box-art-url)
      BOX_ART_URL="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CMS_ID" || -z "$PARENT_GAME_ID" || -z "$GAME_TITLE" ]]; then
  echo "Required: --cms-id, --parent-game-id, and --title" >&2
  exit 2
fi

# One desktop file per variant cmsId so Steam vs Battle.net can coexist.
SAFE_CMS="$(printf '%s' "$CMS_ID" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "$SAFE_CMS" ]]; then
  SAFE_CMS="unknown"
fi

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/gfn"
mkdir -p "$APPS_DIR" "$ICON_DIR"
DESKTOP_PATH="$APPS_DIR/gfn-${SAFE_CMS}.desktop"
ICON_PATH="$ICON_DIR/gfn-${SAFE_CMS}.png"
ICON_VALUE="applications-games"

if [[ -e "$DESKTOP_PATH" && "$FORCE" -ne 1 ]]; then
  echo "Exists (use --force to overwrite): $DESKTOP_PATH" >&2
  echo "$DESKTOP_PATH"
  exit 0
fi

# Escape desktop-entry special characters in Name= / Comment=.
escape_desktop_string() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\n/\\n/g' -e 's/\r/\\r/g'
}

# Desktop Entry Spec: quote args containing reserved chars with double quotes;
# inside quotes escape \, ", `, $.
escape_exec_quoted() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/`/\\`/g' -e 's/\$/\\$/g'
}

SAFE_TITLE="$(escape_desktop_string "$GAME_TITLE")"
STORE_LABEL="$(printf '%s' "$APP_STORE" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$STORE_LABEL" ]]; then
  COMMENT="$(escape_desktop_string "GeForce NOW · ${APP_STORE}")"
  KEYWORDS="$(escape_desktop_string "GeForce NOW;GFN;${APP_STORE};${STORE_LABEL};")"
else
  COMMENT="$(escape_desktop_string "Stream via GeForce NOW (Omarchy plugin matt-dance.gfn)")"
  KEYWORDS="GeForce NOW;GFN;"
fi

# Download / resize GAME_BOX_ART when provided (ImageMagick).
if [[ -n "$BOX_ART_URL" ]]; then
  tmp_img="$(mktemp "${TMPDIR:-/tmp}/gfn-boxart.XXXXXX")"
  if curl -fsSL --max-time 45 -A "matt-dance.gfn-icon/0.1" -o "$tmp_img" "$BOX_ART_URL"; then
    if magick "$tmp_img" -resize '362x512>' -strip "PNG32:${ICON_PATH}" 2>/dev/null \
      || convert "$tmp_img" -resize '362x512>' -strip "PNG32:${ICON_PATH}" 2>/dev/null; then
      ICON_VALUE="$ICON_PATH"
    else
      echo "warning: could not resize box art for $CMS_ID" >&2
    fi
  else
    echo "warning: could not download box art for $CMS_ID" >&2
  fi
  rm -f "$tmp_img"
fi

nv_host="$(flatpak --gl-drivers 2>/dev/null | grep -Eo '^nvidia-[0-9-]+' | head -n 1 || true)"

URL_ROUTE="#?cmsId=${CMS_ID}&launchSource=External&shortName=${SHORT_NAME}&parentGameId=${PARENT_GAME_ID}"
ROUTE_QUOTED="$(escape_exec_quoted "--url-route=${URL_ROUTE}")"

EXEC_LINE="flatpak run --user --command=/app/cef/GeForceNOW --cwd=/app/cef"
if [[ -n "$nv_host" ]]; then
  EXEC_LINE+=" --env=NV_HOST_DRIVER_VERSION=${nv_host}"
  EXEC_LINE+=" --env=NV_FLATPAK_DRIVER_VERSION=${nv_host}"
fi
EXEC_LINE+=" com.nvidia.geforcenow \"${ROUTE_QUOTED}\""

DISPLAY_NAME="$SAFE_TITLE"
if [[ -n "$APP_STORE" ]]; then
  DISPLAY_NAME="$(escape_desktop_string "${GAME_TITLE} (${APP_STORE})")"
fi

cat >"$DESKTOP_PATH" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${DISPLAY_NAME}
GenericName=${SAFE_TITLE} on GeForce NOW
Comment=${COMMENT}
Exec=${EXEC_LINE}
Icon=${ICON_VALUE}
StartupWMClass=GeForceNOW
Categories=Game;
Keywords=${KEYWORDS}
Terminal=false
StartupNotify=true
X-GFN-CmsId=${CMS_ID}
X-GFN-ParentGameId=${PARENT_GAME_ID}
X-GFN-ShortName=${SHORT_NAME}
X-GFN-AppStore=${APP_STORE}
X-Omarchy-Plugin=matt-dance.gfn
EOF

# Best-effort refresh of desktop database when available.
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
  if ! desktop-file-validate "$DESKTOP_PATH"; then
    echo "warning: desktop-file-validate reported issues for $DESKTOP_PATH" >&2
  fi
fi

# Record + sync Omarchy menu game rows (marked gfn-games block).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/matt-dance.gfn"
mkdir -p "$STATE_DIR"
CATALOG="$STATE_DIR/games.json"
python3 - "$CATALOG" "$CMS_ID" "$PARENT_GAME_ID" "$GAME_TITLE" "$SHORT_NAME" "$APP_STORE" "$DESKTOP_PATH" "$ICON_VALUE" <<'PY'
import json, os, sys
path, cms, parent, title, short, store, desktop, icon = sys.argv[1:9]
games = []
if os.path.isfile(path):
    try:
        games = json.loads(open(path, encoding="utf-8").read())
        if not isinstance(games, list):
            games = []
    except Exception:
        games = []
row = {
    "cmsId": cms,
    "parentGameId": parent,
    "title": title,
    "shortName": short,
    "appStore": store,
    "desktop": desktop,
    "icon": icon,
}
games = [g for g in games if str(g.get("cmsId") or "") != cms]
games.append(row)
games.sort(key=lambda g: (str(g.get("title") or "").lower(), str(g.get("appStore") or "")))
open(path, "w", encoding="utf-8").write(json.dumps(games, ensure_ascii=False, indent=2) + "\n")
PY

if [[ -x "${SCRIPT_DIR}/sync-menu-games.sh" ]]; then
  "${SCRIPT_DIR}/sync-menu-games.sh" >/dev/null || true
fi

echo "$DESKTOP_PATH"
