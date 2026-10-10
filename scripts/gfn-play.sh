#!/usr/bin/env bash
# Launch one GeForce NOW title via the proven CEF Flatpak path (HANDOFF).
#
# Busy rules:
#   • Mapped Hyprland window class GeForceNOW → refuse (second --url-route
#     cannot switch games). Never kill an open GFN window / WoW.
#   • Flatpak leftover with NO GeForceNOW window (common after closing a
#     game) → clear that leftover with flatpak kill, then launch cold.
#
# Usage:
#   gfn-play.sh --cms-id <id> --parent-game-id <uuid> [--short-name <slug>] [--title <name>]

set -euo pipefail

CMS_ID=""
PARENT_GAME_ID=""
SHORT_NAME=""
GAME_TITLE="GeForce NOW game"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cms-id) CMS_ID="${2:-}"; shift 2 ;;
    --parent-game-id) PARENT_GAME_ID="${2:-}"; shift 2 ;;
    --short-name) SHORT_NAME="${2:-}"; shift 2 ;;
    --title) GAME_TITLE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CMS_ID" || -z "$PARENT_GAME_ID" ]]; then
  echo "Required: --cms-id and --parent-game-id" >&2
  exit 2
fi

# Desktop / menu launches often lack HYPRLAND_INSTANCE_SIGNATURE; discover it.
ensure_hyprland_signature() {
  if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    return 0
  fi
  local hypr_root="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr"
  local hypr_dir
  hypr_dir="$(find "$hypr_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2- || true)"
  if [[ -n "$hypr_dir" ]]; then
    export HYPRLAND_INSTANCE_SIGNATURE="${hypr_dir##*/}"
  fi
}

gfn_window_open() {
  ensure_hyprland_signature
  hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    cs = json.load(sys.stdin)
except Exception:
    sys.exit(1)
# Mapped (visible) GeForce NOW window = live session; refuse re-launch.
for c in cs:
    if c.get("class") != "GeForceNOW":
        continue
    mapped = c.get("mapped")
    if mapped is False:
        continue
    sys.exit(0)
sys.exit(1)
'
}

gfn_flatpak_running() {
  flatpak ps --columns=application 2>/dev/null | grep -qx "com.nvidia.geforcenow"
}

clear_gfn_leftover() {
  # No mapped window — leftover CEF/flatpak after closing a game. Clear it so
  # a cold --url-route launch can succeed. Never call this when a window is open.
  if ! gfn_flatpak_running; then
    return 0
  fi
  echo "Clearing leftover GeForce NOW (no window) so “${GAME_TITLE}” can launch…" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -a "GeForce NOW Menu" \
      "Clearing leftover GeForce NOW" \
      "No GFN window was open. Starting “${GAME_TITLE}”." || true
  fi
  flatpak kill com.nvidia.geforcenow >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 40); do
    if ! gfn_flatpak_running; then
      return 0
    fi
    sleep 0.1
  done
  echo "Could not clear leftover GeForce NOW (flatpak still listed). Quit it from the tray, then try again." >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -a "GeForce NOW Menu" \
      "Could not clear GeForce NOW" \
      "Quit GeForce NOW completely, then launch “${GAME_TITLE}” again." || true
  fi
  exit 1
}

refuse_busy_window() {
  local msg="GeForce NOW is already open. Close that window completely, then launch “${GAME_TITLE}” again. A second launch cannot switch games."
  echo "$msg" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -a "GeForce NOW Menu" "Close GeForce NOW first" "$msg" || true
  fi
  exit 1
}

if gfn_window_open; then
  refuse_busy_window
fi

# Leftover flatpak with no window blocks cold start — clear, then launch.
if gfn_flatpak_running; then
  clear_gfn_leftover
fi

nv_host="$(flatpak --gl-drivers 2>/dev/null | grep -Eo '^nvidia-[0-9-]+' | head -n 1 || true)"
route="#?cmsId=${CMS_ID}&launchSource=External&shortName=${SHORT_NAME}&parentGameId=${PARENT_GAME_ID}"

exec flatpak run --user \
  --command=/app/cef/GeForceNOW \
  --cwd=/app/cef \
  ${nv_host:+--env=NV_HOST_DRIVER_VERSION="$nv_host"} \
  ${nv_host:+--env=NV_FLATPAK_DRIVER_VERSION="$nv_host"} \
  com.nvidia.geforcenow \
  --url-route="${route}"
