#!/usr/bin/env bash
# Write a GeForce NOW title as a desktop application entry so it appears under
# Omarchy Apps / Super+Space search (same idea as RetroArch Game Launcher).
#
# Usage:
#   write-desktop-entry.sh --cms-id <cmsId> --parent-game-id <uuid> \
#     --title <display-name> [--short-name <slug>] [--force]
#
# --short-name defaults to game_gfn_pc when omitted or empty (Klay convention).
#
# Output path:
#   ~/.local/share/applications/gfn-<sanitized-parent-game-id>.desktop
#
# Exec= uses the Flatpak --url-route pattern from research notes:
#   docs/gfn-linux-launch.md (project agent store)

set -euo pipefail

CMS_ID=""
PARENT_GAME_ID=""
SHORT_NAME=""
GAME_TITLE=""
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
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      sed -n '2,16p' "$0"
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

# Empty shortName from catalog → Klay default (see gfn-linux-launch.md).
if [[ -z "$SHORT_NAME" ]]; then
  SHORT_NAME="game_gfn_pc"
fi

# Sanitize for a stable desktop filename (keep alnum, dash, underscore, dot).
SAFE_ID="$(printf '%s' "$PARENT_GAME_ID" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "$SAFE_ID" ]]; then
  SAFE_ID="unknown"
fi

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS_DIR"
DESKTOP_PATH="$APPS_DIR/gfn-${SAFE_ID}.desktop"

if [[ -e "$DESKTOP_PATH" && "$FORCE" -ne 1 ]]; then
  echo "Exists (use --force to overwrite): $DESKTOP_PATH" >&2
  echo "$DESKTOP_PATH"
  exit 0
fi

# Escape desktop-entry special characters in Name=.
escape_desktop_string() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\n/\\n/g' -e 's/\r/\\r/g'
}

SAFE_TITLE="$(escape_desktop_string "$GAME_TITLE")"

# Quote the entire --url-route argument; do not invent other launch APIs.
URL_ROUTE="#?cmsId=${CMS_ID}&launchSource=External&shortName=${SHORT_NAME}&parentGameId=${PARENT_GAME_ID}"
EXEC_LINE="flatpak run --command=/app/cef/GeForceNOW com.nvidia.geforcenow '--url-route=${URL_ROUTE}'"

cat >"$DESKTOP_PATH" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${SAFE_TITLE}
Comment=Stream via GeForce NOW (Omarchy plugin matt-dance.gfn)
Categories=Game;
Exec=${EXEC_LINE}
Terminal=false
StartupNotify=true
X-GFN-CmsId=${CMS_ID}
X-GFN-ParentGameId=${PARENT_GAME_ID}
X-GFN-ShortName=${SHORT_NAME}
X-Omarchy-Plugin=matt-dance.gfn
EOF

# Best-effort refresh of desktop database when available.
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

echo "$DESKTOP_PATH"
