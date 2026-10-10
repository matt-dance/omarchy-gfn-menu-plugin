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

# Catalog / desktop IDs: reject anything that could split a .desktop line.
readonly GFN_ID_RE='^[A-Za-z0-9._-]{1,64}$'
# Box art: https only, no controls / whitespace / quotes (curl + Icon=).
readonly GFN_HTTPS_RE='^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+$'
# 2 MiB: box-art download cap (curl --max-filesize). Does not bound decoded pixels.
readonly GFN_BOXART_MAX_BYTES=2097152
# Decode bounds: a compact file can declare huge IHDR/SOF dimensions. Catalog art
# is typically ~628x888; 4K / 16MP is a generous ceiling before we refuse.
readonly GFN_BOXART_MAX_WIDTH=4096
readonly GFN_BOXART_MAX_HEIGHT=4096
readonly GFN_BOXART_MAX_PIXELS=16777216
readonly GFN_BOXART_IM_MEMORY="256MiB"
readonly GFN_BOXART_IM_MAP="256MiB"
readonly GFN_BOXART_IM_DISK="256MiB"
readonly GFN_BOXART_IM_TIME=8
readonly GFN_BOXART_TIMEOUT=10

is_safe_id() {
  [[ -n "$1" && "$1" =~ $GFN_ID_RE ]]
}

# Strip C0 controls and DEL. Bash argv cannot carry NUL; tr still drops it.
strip_controls() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'
}

# Desktop Entry string escapes: \\ \n \t \r and leading/trailing \s.
# Control characters should already have been stripped; these remain as defense.
escape_desktop_string() {
  local s="$1" lead=0 tail=0 mid
  s="${s//\\/\\\\}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  mid="$s"
  while [[ "$mid" == ' '* ]]; do
    lead=$((lead + 1))
    mid="${mid# }"
  done
  while [[ "$mid" == *' ' ]]; do
    tail=$((tail + 1))
    mid="${mid% }"
  done
  local i out=""
  for ((i = 0; i < lead; i++)); do
    out+='\s'
  done
  out+="$mid"
  for ((i = 0; i < tail; i++)); do
    out+='\s'
  done
  printf '%s' "$out"
}

# Exec argument: always double-quoted. Escape \, ", `, $; literal % → %%.
# Caller must strip controls first so the value cannot split Exec=.
quote_exec_arg() {
  local s="$1"
  s="${s//%/%%}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\`/\\\`}"
  s="${s//\$/\\\$}"
  printf '"%s"' "$s"
}

# Fail closed if a sanitized value still contains a line break (injection).
assert_single_line() {
  local name="$1" value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "error: ${name} contains a CR/LF after sanitizing; refusing to write" >&2
    exit 1
  fi
}

require_id() {
  local name="$1" value="$2"
  if ! is_safe_id "$value"; then
    echo "error: ${name} must match ${GFN_ID_RE} (got $(printf '%q' "$value"))" >&2
    exit 2
  fi
}

require_optional_id() {
  local name="$1" value="$2"
  if [[ -n "$value" ]] && ! is_safe_id "$value"; then
    echo "error: ${name} must be empty or match ${GFN_ID_RE} (got $(printf '%q' "$value"))" >&2
    exit 2
  fi
}

# Wall-clock cap around ImageMagick. -limit time is CPU-ish; timeout is elapsed.
gfn_run_im() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=2s "$GFN_BOXART_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Shared -limit argv for IM6 (identify/convert) and IM7 (magick …).
# Width/height omitted when $1 is "ping" so identify can report declared size.
gfn_im_limit_args() {
  if [[ "${1:-}" != ping ]]; then
    printf '%s\n' \
      -limit width "$GFN_BOXART_MAX_WIDTH" \
      -limit height "$GFN_BOXART_MAX_HEIGHT"
  fi
  printf '%s\n' \
    -limit area "$GFN_BOXART_MAX_PIXELS" \
    -limit memory "$GFN_BOXART_IM_MEMORY" \
    -limit map "$GFN_BOXART_IM_MAP" \
    -limit disk "$GFN_BOXART_IM_DISK" \
    -limit list-length 4 \
    -limit time "$GFN_BOXART_IM_TIME"
}

# Header-only width/height (no pixel cache). IM7: magick identify; IM6: identify.
gfn_box_art_ping() {
  local src="$1" out=""
  local -a limits=()
  mapfile -t limits < <(gfn_im_limit_args ping)
  if command -v magick >/dev/null 2>&1; then
    out="$(gfn_run_im magick "${limits[@]}" identify -ping -format '%w %h' "$src")" || return 1
  elif command -v identify >/dev/null 2>&1; then
    out="$(gfn_run_im identify "${limits[@]}" -ping -format '%w %h' "$src")" || return 1
  else
    return 1
  fi
  printf '%s' "$out"
}

gfn_box_art_dims_ok() {
  local raw="$1" w h extra
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/ }"
  read -r w h extra <<<"$raw"
  if [[ -n "${extra:-}" || ! "$w" =~ ^[1-9][0-9]*$ || ! "$h" =~ ^[1-9][0-9]*$ ]]; then
    return 1
  fi
  if ((10#$w > GFN_BOXART_MAX_WIDTH || 10#$h > GFN_BOXART_MAX_HEIGHT || 10#$w * 10#$h > GFN_BOXART_MAX_PIXELS)); then
    echo "warning: rejecting box art for $CMS_ID (${w}x${h} exceeds decode limits)" >&2
    return 1
  fi
  return 0
}

# Full decode + resize, with decoder dimension/memory/disk/time limits.
gfn_box_art_resize() {
  local src="$1" dest="$2"
  local -a limits=()
  mapfile -t limits < <(gfn_im_limit_args)
  if command -v magick >/dev/null 2>&1; then
    gfn_run_im magick "${limits[@]}" "$src" -resize '362x512>' -strip "PNG32:${dest}"
  elif command -v convert >/dev/null 2>&1; then
    gfn_run_im convert "${limits[@]}" "$src" -resize '362x512>' -strip "PNG32:${dest}"
  else
    return 1
  fi
}

gfn_install_box_art() {
  local src="$1" dest="$2" dims=""
  if ! dims="$(gfn_box_art_ping "$src" 2>/dev/null)"; then
    echo "warning: could not resize box art for $CMS_ID" >&2
    return 1
  fi
  if ! gfn_box_art_dims_ok "$dims"; then
    return 1
  fi
  if gfn_box_art_resize "$src" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$dest"
  echo "warning: could not resize box art for $CMS_ID" >&2
  return 1
}

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

# IDs / store tokens are allowlisted before any file is touched.
require_id "--cms-id" "$CMS_ID"
require_id "--parent-game-id" "$PARENT_GAME_ID"
require_optional_id "--short-name" "$SHORT_NAME"
require_optional_id "--app-store" "$APP_STORE"

GAME_TITLE="$(strip_controls "$GAME_TITLE")"
# Trim surrounding whitespace after control strip.
GAME_TITLE="${GAME_TITLE#"${GAME_TITLE%%[![:space:]]*}"}"
GAME_TITLE="${GAME_TITLE%"${GAME_TITLE##*[![:space:]]}"}"
if [[ -z "$GAME_TITLE" ]]; then
  echo "error: --title is empty after removing control characters" >&2
  exit 2
fi

if [[ -n "$BOX_ART_URL" ]]; then
  BOX_ART_URL="$(strip_controls "$BOX_ART_URL")"
  if [[ ! "$BOX_ART_URL" =~ $GFN_HTTPS_RE ]]; then
    echo "warning: ignoring unsafe --box-art-url (https only, no controls)" >&2
    BOX_ART_URL=""
  fi
fi

# One desktop file per variant cmsId so Steam vs Battle.net can coexist.
SAFE_CMS="$(printf '%s' "$CMS_ID" | tr '[:upper:]' '[:lower:]')"

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/gfn"
mkdir -p "$APPS_DIR" "$ICON_DIR"
DESKTOP_PATH="$APPS_DIR/gfn-${SAFE_CMS}.desktop"
ICON_PATH="$ICON_DIR/gfn-${SAFE_CMS}.png"
ICON_VALUE="applications-games"
# Keep an existing resized box-art icon across --force rewrites without --box-art-url.
if [[ -f "$ICON_PATH" ]]; then
  ICON_VALUE="$ICON_PATH"
fi

if [[ -e "$DESKTOP_PATH" && "$FORCE" -ne 1 ]]; then
  echo "Exists (use --force to overwrite): $DESKTOP_PATH" >&2
  echo "$DESKTOP_PATH"
  exit 0
fi

SAFE_TITLE="$(escape_desktop_string "$GAME_TITLE")"
STORE_LABEL="$(printf '%s' "$APP_STORE" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$STORE_LABEL" ]]; then
  COMMENT="$(escape_desktop_string "GeForce NOW · ${APP_STORE}")"
  KEYWORDS="$(escape_desktop_string "GeForce NOW;GFN;${APP_STORE};${STORE_LABEL};")"
else
  COMMENT="$(escape_desktop_string "Stream via GeForce NOW (Omarchy plugin matt-dance.gfn-omarchy)")"
  KEYWORDS="$(escape_desktop_string "GeForce NOW;GFN;")"
fi

tmp_img=""
tmp_dir=""
cleanup() {
  if [[ -n "${tmp_img:-}" ]]; then
    rm -f "$tmp_img"
  fi
  if [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

# Download / resize GAME_BOX_ART when provided (ImageMagick).
if [[ -n "$BOX_ART_URL" ]]; then
  tmp_img="$(mktemp "${TMPDIR:-/tmp}/gfn-boxart.XXXXXX")"
  if curl -fsSL \
    --proto '=https' \
    --proto-redir '=https' \
    --max-filesize "$GFN_BOXART_MAX_BYTES" \
    --max-time 45 \
    -A "matt-dance.gfn-omarchy-icon/0.1" \
    -o "$tmp_img" \
    -- \
    "$BOX_ART_URL"; then
    if gfn_install_box_art "$tmp_img" "$ICON_PATH"; then
      ICON_VALUE="$ICON_PATH"
    fi
  else
    echo "warning: could not download box art for $CMS_ID" >&2
  fi
  rm -f "$tmp_img"
  tmp_img=""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAY_SCRIPT="${SCRIPT_DIR}/gfn-play.sh"
# Desktop Exec: double-quote every argument (desktop-file-validate rejects bash '' quoting).
# Keyfile-unescape happens before Exec parsing, so quote then escape the whole line.
EXEC_LINE="bash $(quote_exec_arg "$PLAY_SCRIPT") --cms-id $(quote_exec_arg "$CMS_ID") --parent-game-id $(quote_exec_arg "$PARENT_GAME_ID") --short-name $(quote_exec_arg "$SHORT_NAME") --title $(quote_exec_arg "$GAME_TITLE")"
EXEC_LINE="$(escape_desktop_string "$EXEC_LINE")"

# Matt UX: primary "GFN - <Game>"; store is the small print (Comment).
STORE_PRETTY="$(printf '%s' "$APP_STORE" | tr '[:lower:]' '[:upper:]')"
case "$STORE_PRETTY" in
  STEAM) STORE_PRETTY="Steam" ;;
  BATTLENET) STORE_PRETTY="Battle.net" ;;
  EPIC) STORE_PRETTY="Epic" ;;
  GOG) STORE_PRETTY="GOG" ;;
  UPLAY|UBISOFT) STORE_PRETTY="Ubisoft" ;;
  EA) STORE_PRETTY="EA" ;;
  "") STORE_PRETTY="" ;;
esac
DISPLAY_NAME="$(escape_desktop_string "GFN - ${GAME_TITLE}")"
if [[ -n "$STORE_PRETTY" ]]; then
  COMMENT="$(escape_desktop_string "${STORE_PRETTY}")"
else
  COMMENT="$(escape_desktop_string "GeForce NOW")"
fi

ICON_ESCAPED="$(escape_desktop_string "$ICON_VALUE")"
X_CMS="$(escape_desktop_string "$CMS_ID")"
X_PARENT="$(escape_desktop_string "$PARENT_GAME_ID")"
X_SHORT="$(escape_desktop_string "$SHORT_NAME")"
X_STORE="$(escape_desktop_string "$APP_STORE")"

assert_single_line "Name" "$DISPLAY_NAME"
assert_single_line "GenericName" "$SAFE_TITLE"
assert_single_line "Comment" "$COMMENT"
assert_single_line "Exec" "$EXEC_LINE"
assert_single_line "Icon" "$ICON_ESCAPED"
assert_single_line "Keywords" "$KEYWORDS"
assert_single_line "X-GFN-CmsId" "$X_CMS"
assert_single_line "X-GFN-ParentGameId" "$X_PARENT"
assert_single_line "X-GFN-ShortName" "$X_SHORT"
assert_single_line "X-GFN-AppStore" "$X_STORE"

# Atomic install: write + validate a temp file, then mv into place.
# Hidden dir under applications/ so a crash cannot leave a launchable entry.
tmp_dir="$(mktemp -d -p "$APPS_DIR" ".gfn-write.XXXXXX")"
tmp_desktop="${tmp_dir}/gfn-${SAFE_CMS}.desktop"

cat >"$tmp_desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${DISPLAY_NAME}
GenericName=${SAFE_TITLE}
Comment=${COMMENT}
Exec=${EXEC_LINE}
Icon=${ICON_ESCAPED}
StartupWMClass=GeForceNOW
Categories=Game;
Keywords=${KEYWORDS}
Terminal=false
StartupNotify=true
X-GFN-CmsId=${X_CMS}
X-GFN-ParentGameId=${X_PARENT}
X-GFN-ShortName=${X_SHORT}
X-GFN-AppStore=${X_STORE}
X-Omarchy-Plugin=matt-dance.gfn-omarchy
EOF

if command -v desktop-file-validate >/dev/null 2>&1; then
  if ! desktop-file-validate "$tmp_desktop"; then
    echo "error: desktop-file-validate failed; not installing ${DESKTOP_PATH}" >&2
    exit 1
  fi
fi

mv -f "$tmp_desktop" "$DESKTOP_PATH"
rmdir "$tmp_dir"
tmp_dir=""

# Best-effort refresh of desktop database when available.
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

# Record + sync Omarchy menu game rows (marked gfn-games block).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/matt-dance.gfn-omarchy"
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
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(games, ensure_ascii=False, indent=2) + "\n")
os.replace(tmp, path)
PY

if [[ -x "${SCRIPT_DIR}/sync-menu-games.sh" ]]; then
  "${SCRIPT_DIR}/sync-menu-games.sh" >/dev/null || true
fi

# Desktop notification so overlay Enter-add is visible even without UI focus.
NOTIFY_TITLE="Added GFN - ${GAME_TITLE}"
NOTIFY_BODY="Gaming → GeForce NOW"
if [[ -n "$STORE_PRETTY" ]]; then
  NOTIFY_BODY="${STORE_PRETTY} · Gaming → GeForce NOW"
fi
if command -v notify-send >/dev/null 2>&1; then
  notify-send -a "GeForce NOW Menu" "$NOTIFY_TITLE" "$NOTIFY_BODY" || true
fi

echo "$DESKTOP_PATH"
