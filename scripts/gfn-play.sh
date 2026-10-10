#!/usr/bin/env bash
# Launch one GeForce NOW title via the proven CEF Flatpak path (HANDOFF).
# If GeForce NOW is already running, refuse — a second --url-route does not
# switch games (logs the route and exits). Never kills GeForce NOW / WoW.
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
      sed -n '2,12p' "$0"
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

gfn_window_open() {
  hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    cs = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if any(c.get("class") == "GeForceNOW" for c in cs) else 1)
'
}

gfn_flatpak_running() {
  # Covers leftover CEF with no mapped window (common "launch then nothing").
  flatpak ps --columns=application 2>/dev/null | grep -qx "com.nvidia.geforcenow"
}

refuse_busy() {
  local msg="GeForce NOW is already running. Close it completely, then launch “${GAME_TITLE}” again. A second launch cannot switch games."
  echo "$msg" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -a "GeForce NOW Menu" "Close GeForce NOW first" "$msg" || true
  fi
  exit 1
}

if gfn_window_open || gfn_flatpak_running; then
  refuse_busy
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
