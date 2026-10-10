#!/usr/bin/env bash
# Launch one GeForce NOW title via the proven CEF Flatpak path (HANDOFF).
#
# Busy rules:
#   • GeForce NOW window managed by Hyprland → refuse. A second --url-route
#     cannot switch games. Never kill that.
#   • Flatpak running with no Hyprland window (closed to tray, or hung before
#     its first frame) → clear it and the Chromium SingletonLock, then
#     cold-launch. Never touch WoW.
#
# GFN's SDL audio init blocks until WirePlumber grants its Flatpak PipeWire
# client permissions. If WirePlumber is wedged (seen after a sound-driver
# reload), GFN never paints and no window appears. The launcher detects that,
# restarts WirePlumber once, and relaunches.

set -euo pipefail

CMS_ID=""
PARENT_GAME_ID=""
SHORT_NAME=""
GAME_TITLE="GeForce NOW game"
APP_ID="com.nvidia.geforcenow"
CEF_CACHE="$HOME/.var/app/$APP_ID/.local/state/NVIDIA/GeForceNOW/CefCache"

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

notify() {
  local urgency="$1" summary="$2" body="$3"
  echo "$summary: $body" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u "$urgency" -a "GeForce NOW Menu" "$summary" "$body" || true
  fi
}

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
sys.exit(0 if any(c.get("class") == "GeForceNOW" and c.get("mapped") is not False for c in cs) else 1)
'
}

gfn_flatpak_running() {
  flatpak ps --columns=application 2>/dev/null | grep -qx "$APP_ID"
}

clear_singleton_locks() {
  rm -f "$CEF_CACHE/SingletonLock" "$CEF_CACHE/SingletonSocket" "$CEF_CACHE/SingletonCookie" 2>/dev/null || true
}

stop_gfn() {
  flatpak kill "$APP_ID" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 40); do
    gfn_flatpak_running || break
    sleep 0.1
  done
  clear_singleton_locks
  ! gfn_flatpak_running
}

# Exit 0 if GFN has a PipeWire client that WirePlumber left with no permissions.
gfn_audio_blocked() {
  command -v pw-dump >/dev/null 2>&1 && command -v pw-cli >/dev/null 2>&1 || return 1
  local id
  for id in $(pw-dump 2>/dev/null | python3 -c '
import json, sys
try:
    objs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in objs:
    if o.get("type") != "PipeWire:Interface:Client":
        continue
    props = (o.get("info") or {}).get("props") or {}
    if props.get("pipewire.access.portal.app_id") == sys.argv[1]:
        print(o["id"])
' "$APP_ID"); do
    if pw-cli get-permissions "$id" 2>/dev/null | grep -q 'default: -----'; then
      return 0
    fi
  done
  return 1
}

start_gfn() {
  local nv_host route
  nv_host="$(flatpak --gl-drivers 2>/dev/null | grep -Eo '^nvidia-[0-9-]+' | head -n 1 || true)"
  route="#?cmsId=${CMS_ID}&launchSource=External&shortName=${SHORT_NAME}&parentGameId=${PARENT_GAME_ID}"
  flatpak run --user \
    --command=/app/cef/GeForceNOW \
    --cwd=/app/cef \
    ${nv_host:+--env=NV_HOST_DRIVER_VERSION="$nv_host"} \
    ${nv_host:+--env=NV_FLATPAK_DRIVER_VERSION="$nv_host"} \
    "$APP_ID" \
    --url-route="${route}" &
  FPID=$!
}

# Returns 0 when a window appears, 1 on audio hang, 2 on timeout or exit.
wait_for_window() {
  local i blocked=0
  for i in $(seq 1 120); do
    gfn_window_open && return 0
    if ! kill -0 "$FPID" 2>/dev/null && ! gfn_flatpak_running; then
      return 2
    fi
    if (( i % 8 == 0 )); then
      if gfn_audio_blocked; then
        blocked=$((blocked + 1))
        (( blocked >= 2 )) && return 1
      else
        blocked=0
      fi
    fi
    sleep 0.25
  done
  return 2
}

if gfn_window_open; then
  notify normal "Close GeForce NOW first" \
    "GeForce NOW is already open. Close that window completely, then launch “${GAME_TITLE}” again. A second launch cannot switch games."
  exit 1
fi

if gfn_flatpak_running; then
  echo "Clearing leftover GeForce NOW (no window) so “${GAME_TITLE}” can launch…" >&2
  if ! stop_gfn; then
    notify normal "Could not clear GeForce NOW" \
      "Quit GeForce NOW completely, then launch “${GAME_TITLE}” again."
    exit 1
  fi
else
  clear_singleton_locks
fi

FPID=""
start_gfn
set +e
wait_for_window
status=$?
set -e

if [[ "$status" -eq 1 ]]; then
  notify normal "Restarting audio for GeForce NOW" \
    "WirePlumber did not let GeForce NOW use audio, so its window could not open. Restarting WirePlumber and relaunching “${GAME_TITLE}”."
  stop_gfn || true
  wait "$FPID" 2>/dev/null || true
  systemctl --user restart wireplumber || true
  sleep 2
  start_gfn
  set +e
  wait_for_window
  status=$?
  set -e
fi

if [[ "$status" -ne 0 ]]; then
  if [[ "$status" -eq 1 ]]; then
    notify critical "GeForce NOW is stuck on audio" \
      "WirePlumber still blocks GeForce NOW after a restart. Log out and back in, then launch “${GAME_TITLE}” again."
  else
    notify critical "GFN window not visible" \
      "GeForce NOW started for “${GAME_TITLE}” but no window appeared. Quit it from the tray and launch again."
  fi
fi

wait "$FPID"
exit $?
