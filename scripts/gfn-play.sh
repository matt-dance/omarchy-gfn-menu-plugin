#!/usr/bin/env bash
# Launch one GeForce NOW title via the proven CEF Flatpak path (HANDOFF).
#
# Busy rules:
#   • Visible GeForce NOW session (Hyprland client OR mapped X11 window) →
#     refuse — a second --url-route cannot switch games. Never kill that.
#   • Flatpak leftover / stale Chromium SingletonLock with no visible window
#     (common after close, or after a headless agent launch) → clear, then
#     cold-launch. Never touch WoW.
#
# After start: wait briefly for a real window; try to map withdrawn X11
# GeForceNOW windows so they show under Hyprland.

set -euo pipefail

CMS_ID=""
PARENT_GAME_ID=""
SHORT_NAME=""
GAME_TITLE="GeForce NOW game"
CEF_CACHE="${XDG_DATA_HOME:-$HOME/.local/share}/../.var/app/com.nvidia.geforcenow/.local/state/NVIDIA/GeForceNOW/CefCache"
# Prefer flatpak state path under home:
CEF_CACHE="$HOME/.var/app/com.nvidia.geforcenow/.local/state/NVIDIA/GeForceNOW/CefCache"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cms-id) CMS_ID="${2:-}"; shift 2 ;;
    --parent-game-id) PARENT_GAME_ID="${2:-}"; shift 2 ;;
    --short-name) SHORT_NAME="${2:-}"; shift 2 ;;
    --title) GAME_TITLE="${2:-}"; shift 2 ;;
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

if [[ -z "$CMS_ID" || -z "$PARENT_GAME_ID" ]]; then
  echo "Required: --cms-id and --parent-game-id" >&2
  exit 2
fi

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

# Exit 0 if Hyprland has a mapped GeForceNOW client.
gfn_hypr_window_open() {
  ensure_hyprland_signature
  hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    cs = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for c in cs:
    if c.get("class") != "GeForceNOW":
        continue
    if c.get("mapped") is False:
        continue
    sys.exit(0)
sys.exit(1)
'
}

# Exit 0 if a meaningful X11 GeForceNOW window is mapped (Viewable, >= 200px).
# Hyprland sometimes omits these from `clients` while the X window still exists.
gfn_x11_window_open() {
  DISPLAY="${DISPLAY:-:0}" python3 - <<'PY' 2>/dev/null
import sys
try:
    from Xlib import display
except Exception:
    sys.exit(1)
try:
    d = display.Display()
except Exception:
    sys.exit(1)
root = d.screen().root

def walk(w):
    try:
        children = w.query_tree().children
    except Exception:
        return False
    for c in children:
        try:
            wm = c.get_wm_class()
        except Exception:
            wm = None
        if wm and "GeForceNOW" in str(wm):
            try:
                attrs = c.get_attributes()
                geo = c.get_geometry()
            except Exception:
                continue
            # map_state 2 == IsViewable
            if attrs.map_state == 2 and geo.width >= 200 and geo.height >= 200:
                return True
        if walk(c):
            return True
    return False

sys.exit(0 if walk(root) else 1)
PY
}

gfn_visible_session() {
  gfn_hypr_window_open || gfn_x11_window_open
}

gfn_flatpak_running() {
  flatpak ps --columns=application 2>/dev/null | grep -qx "com.nvidia.geforcenow"
}

clear_singleton_locks() {
  # Stale Chromium singleton after flatpak kill → next CEF starts and shows nothing.
  rm -f "$CEF_CACHE/SingletonLock" "$CEF_CACHE/SingletonSocket" "$CEF_CACHE/SingletonCookie" 2>/dev/null || true
}

# Try to map withdrawn / tiny GeForceNOW X11 windows so they can appear.
try_map_x11_gfn_windows() {
  DISPLAY="${DISPLAY:-:0}" python3 - <<'PY' 2>/dev/null || true
import sys
try:
    from Xlib import display, X
except Exception:
    sys.exit(0)
try:
    d = display.Display()
except Exception:
    sys.exit(0)
root = d.screen().root

def walk(w):
    try:
        children = w.query_tree().children
    except Exception:
        return
    for c in children:
        try:
            wm = c.get_wm_class()
        except Exception:
            wm = None
        if wm and "GeForceNOW" in str(wm):
            try:
                attrs = c.get_attributes()
                if attrs.map_state != 2:
                    c.map()
                # Ask for NormalState / activation.
                try:
                    hints = c.get_wm_hints()
                    if hints is not None:
                        hints.flags = (hints.flags or 0) | 2  # StateHint
                        hints.initial_state = 1  # NormalState
                        c.set_wm_hints(hints)
                except Exception:
                    pass
                try:
                    NET_ACTIVE = d.intern_atom("_NET_ACTIVE_WINDOW")
                    ev = X.ClientMessage(
                        window=c,
                        client_type=NET_ACTIVE,
                        data=(32, [2, X.CurrentTime, 0, 0, 0]),
                    )
                    # Some Xlib builds want a different constructor; ignore failures.
                    root.send_event(ev, event_mask=X.SubstructureRedirectMask | X.SubstructureNotifyMask)
                except Exception:
                    pass
                d.sync()
            except Exception:
                pass
        walk(c)

walk(root)
PY
}

clear_gfn_leftover() {
  if ! gfn_flatpak_running; then
    clear_singleton_locks
    return 0
  fi
  echo "Clearing leftover GeForce NOW (no visible window) so “${GAME_TITLE}” can launch…" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -a "GeForce NOW Menu" \
      "Clearing leftover GeForce NOW" \
      "No GFN window was open. Starting “${GAME_TITLE}”." || true
  fi
  flatpak kill com.nvidia.geforcenow >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 40); do
    if ! gfn_flatpak_running; then
      break
    fi
    sleep 0.1
  done
  clear_singleton_locks
  if gfn_flatpak_running; then
    echo "Could not clear leftover GeForce NOW. Quit it from the tray, then try again." >&2
    if command -v notify-send >/dev/null 2>&1; then
      notify-send -u normal -a "GeForce NOW Menu" \
        "Could not clear GeForce NOW" \
        "Quit GeForce NOW completely, then launch “${GAME_TITLE}” again." || true
    fi
    exit 1
  fi
}

refuse_busy_window() {
  local msg="GeForce NOW is already open. Close that window completely, then launch “${GAME_TITLE}” again. A second launch cannot switch games."
  echo "$msg" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -a "GeForce NOW Menu" "Close GeForce NOW first" "$msg" || true
  fi
  exit 1
}

if gfn_visible_session; then
  refuse_busy_window
fi

if gfn_flatpak_running; then
  clear_gfn_leftover
else
  clear_singleton_locks
fi

nv_host="$(flatpak --gl-drivers 2>/dev/null | grep -Eo '^nvidia-[0-9-]+' | head -n 1 || true)"
route="#?cmsId=${CMS_ID}&launchSource=External&shortName=${SHORT_NAME}&parentGameId=${PARENT_GAME_ID}"

# Run without exec so we can wait for a visible window and recover withdrawn X11 surfaces.
set +e
flatpak run --user \
  --command=/app/cef/GeForceNOW \
  --cwd=/app/cef \
  ${nv_host:+--env=NV_HOST_DRIVER_VERSION="$nv_host"} \
  ${nv_host:+--env=NV_FLATPAK_DRIVER_VERSION="$nv_host"} \
  com.nvidia.geforcenow \
  --url-route="${route}" &
FPID=$!
set -e

# Give CEF time to create a window; nudge withdrawn X11 surfaces.
visible=0
for i in $(seq 1 40); do
  if gfn_visible_session; then
    visible=1
    break
  fi
  if [[ $i -eq 8 || $i -eq 16 || $i -eq 24 ]]; then
    try_map_x11_gfn_windows
  fi
  # Still running?
  if ! kill -0 "$FPID" 2>/dev/null && ! gfn_flatpak_running; then
    break
  fi
  sleep 0.25
done

if [[ "$visible" -eq 0 ]]; then
  try_map_x11_gfn_windows
  sleep 0.5
  if gfn_visible_session; then
    visible=1
  fi
fi

if [[ "$visible" -eq 0 ]]; then
  echo "GeForce NOW started but no window appeared for “${GAME_TITLE}”. If another app is fullscreen, exit fullscreen. Or quit GFN from the tray and try again." >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -a "GeForce NOW Menu" \
      "GFN window not visible" \
      "Process started for “${GAME_TITLE}” but no window showed. Exit fullscreen apps, or quit GeForce NOW and launch again." || true
  fi
fi

wait "$FPID"
exit $?
