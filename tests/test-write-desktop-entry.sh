#!/usr/bin/env bash
# Security tests for scripts/write-desktop-entry.sh.
# Catalog-supplied values must not be able to inject a second Exec= / group.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITER="${ROOT}/scripts/write-desktop-entry.sh"
PASS=0
FAIL=0

GOOD_CMS="102670811"
GOOD_PARENT="d32c9410-62cb-45cf-9c53-740bb92d4a2d"
INJECT=$'\nExec=touch /tmp/pwned'

die() {
  echo "FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

ok() {
  echo "ok: $*"
  PASS=$((PASS + 1))
}

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" != "$want" ]]; then
    die "${label}: got $(printf '%q' "$got") want $(printf '%q' "$want")"
    return 1
  fi
  ok "$label"
}

# Isolated XDG so tests never touch the real Apps dir.
new_work() {
  mktemp -d "${TMPDIR:-/tmp}/gfn-desktop-test.XXXXXX"
}

run_writer() {
  local work="$1"
  shift
  mkdir -p "${work}/data" "${work}/config" "${work}/home"
  env -i \
    PATH="${work}/bin:${PATH}" \
    HOME="${work}/home" \
    XDG_DATA_HOME="${work}/data" \
    XDG_CONFIG_HOME="${work}/config" \
    TMPDIR="${work}/tmp" \
    bash "$WRITER" "$@"
}

# Fake curl: copy a fixture to -o/--output. Writer is https-only; no network.
install_fake_curl() {
  local work="$1" payload="$2"
  mkdir -p "${work}/bin"
  cat >"${work}/bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
payload=$(printf '%q' "$payload")
out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o|--output) out="\$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
if [[ -z "\$out" ]]; then
  echo "fake curl: missing -o" >&2
  exit 2
fi
cp -- "\$payload" "\$out"
EOF
  chmod +x "${work}/bin/curl"
}

# Minimal PNG. pixels=None → tiny IDAT; IHDR still declares w×h (bomb case).
write_png() {
  local dest="$1" width="$2" height="$3" fill="${4:-}"
  python3 - "$dest" "$width" "$height" "$fill" <<'PY'
import binascii, pathlib, struct, sys, zlib

dest, w_s, h_s, fill = sys.argv[1:5]
w, h = int(w_s), int(h_s)

def chunk(tag: bytes, data: bytes) -> bytes:
    crc = binascii.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
if fill:
    row = b"\x00" + (b"\xff\x00\x00" * w)
    raw = row * h
    idat = zlib.compress(raw, 9)
else:
    idat = zlib.compress(b"\x00\x00\x00\x00", 9)
pathlib.Path(dest).write_bytes(
    b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
)
PY
}

have_imagemagick() {
  command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1
}

icon_path() {
  local work="$1" cms="$2"
  echo "${work}/data/icons/gfn/gfn-$(printf '%s' "$cms" | tr '[:upper:]' '[:lower:]').png"
}

desktop_path() {
  local work="$1" cms="$2"
  echo "${work}/data/applications/gfn-$(printf '%s' "$cms" | tr '[:upper:]' '[:lower:]').desktop"
}

assert_safe_desktop() {
  local file="$1" label="$2"
  if [[ ! -f "$file" ]]; then
    die "${label}: desktop file was not written (${file})"
    return 1
  fi
  local groups execs
  groups="$(grep -c '^\[Desktop Entry\]' "$file" || true)"
  execs="$(grep -c '^Exec=' "$file" || true)"
  if [[ "$groups" != 1 ]]; then
    die "${label}: expected 1 [Desktop Entry] group, got ${groups}"
    return 1
  fi
  if [[ "$execs" != 1 ]]; then
    die "${label}: expected 1 Exec= line, got ${execs}"
    echo "----- ${file} -----" >&2
    cat "$file" >&2
    return 1
  fi
  if grep -q '^Exec=touch ' "$file"; then
    die "${label}: injected Exec=touch line present"
    return 1
  fi
  if command -v desktop-file-validate >/dev/null 2>&1; then
    if ! desktop-file-validate "$file"; then
      die "${label}: desktop-file-validate failed"
      return 1
    fi
  fi
  ok "${label}: one group, one Exec=, validate ok"
}

assert_refused_no_file() {
  local work="$1" cms="$2" label="$3" rc="$4"
  local file
  file="$(desktop_path "$work" "$cms")"
  if [[ "$rc" -eq 0 ]]; then
    die "${label}: writer succeeded; expected refuse"
    return 1
  fi
  if [[ -e "$file" ]]; then
    die "${label}: refused but left ${file}"
    return 1
  fi
  if [[ -e "${work}/data/matt-dance.gfn-omarchy/games.json" ]]; then
    die "${label}: refused but wrote games.json"
    return 1
  fi
  ok "${label}: refused (exit ${rc}), wrote nothing"
}

# --- happy path -------------------------------------------------------------
work="$(new_work)"
mkdir -p "${work}/tmp"
rc=0
run_writer "$work" \
  --cms-id "$GOOD_CMS" \
  --parent-game-id "$GOOD_PARENT" \
  --title "Diablo IV" \
  --short-name "" \
  --app-store "STEAM" \
  --force >/dev/null || rc=$?
assert_eq "happy path exit" "$rc" "0"
assert_safe_desktop "$(desktop_path "$work" "$GOOD_CMS")" "happy path"
if grep -q '^X-GFN-CmsId=102670811$' "$(desktop_path "$work" "$GOOD_CMS")"; then
  ok "happy path X-GFN-CmsId"
else
  die "happy path missing X-GFN-CmsId"
fi
if grep -q '^Name=GFN - Diablo IV$' "$(desktop_path "$work" "$GOOD_CMS")"; then
  ok "happy path Name is GFN - Diablo IV"
else
  die "happy path Name wrong: $(grep '^Name=' "$(desktop_path "$work" "$GOOD_CMS")")"
fi
if grep -q '^GenericName=Diablo IV$' "$(desktop_path "$work" "$GOOD_CMS")"; then
  ok "happy path GenericName is bare title"
else
  die "happy path GenericName wrong: $(grep '^GenericName=' "$(desktop_path "$work" "$GOOD_CMS")")"
fi
if grep -q '^Comment=Steam$' "$(desktop_path "$work" "$GOOD_CMS")"; then
  ok "happy path Comment is store"
else
  die "happy path Comment wrong: $(grep '^Comment=' "$(desktop_path "$work" "$GOOD_CMS")")"
fi
rm -rf "$work"

# --- GFN prefix is idempotent (overlay may pass "GFN - <Game>") ------------
for pre_title in "GFN - Diablo IV" "GFN - GFN - Diablo IV" "GFN -  GFN - Diablo IV"; do
  work="$(new_work)"
  mkdir -p "${work}/tmp"
  rc=0
  run_writer "$work" \
    --cms-id "$GOOD_CMS" \
    --parent-game-id "$GOOD_PARENT" \
    --title "$pre_title" \
    --short-name "" \
    --app-store "STEAM" \
    --force >/dev/null || rc=$?
  assert_eq "idempotent prefix exit (${pre_title})" "$rc" "0"
  desk="$(desktop_path "$work" "$GOOD_CMS")"
  assert_safe_desktop "$desk" "idempotent (${pre_title})"
  name="$(grep '^Name=' "$desk" | head -1)"
  assert_eq "idempotent Name (${pre_title})" "$name" "Name=GFN - Diablo IV"
  gname="$(grep '^GenericName=' "$desk" | head -1)"
  assert_eq "idempotent GenericName (${pre_title})" "$gname" "GenericName=Diablo IV"
  catalog="${work}/data/matt-dance.gfn-omarchy/games.json"
  if [[ -f "$catalog" ]] && python3 -c 'import json,sys; g=json.load(open(sys.argv[1])); assert g[0]["title"]=="Diablo IV"' "$catalog"; then
    ok "idempotent games.json bare title (${pre_title})"
  else
    die "idempotent games.json title not bare for ${pre_title}: $(cat "$catalog" 2>/dev/null || true)"
  fi
  rm -rf "$work"
done

# --- ID fields: newline + Exec= must refuse and write nothing --------------
for field in --cms-id --parent-game-id --short-name --app-store; do
  work="$(new_work)"
  mkdir -p "${work}/tmp"
  rc=0
  case "$field" in
    --cms-id)
      run_writer "$work" \
        --cms-id "${GOOD_CMS}${INJECT}" \
        --parent-game-id "$GOOD_PARENT" \
        --title "Diablo IV" \
        --force >/dev/null 2>"${work}/err" || rc=$?
      cms_for_path="$GOOD_CMS"
      ;;
    --parent-game-id)
      run_writer "$work" \
        --cms-id "$GOOD_CMS" \
        --parent-game-id "${GOOD_PARENT}${INJECT}" \
        --title "Diablo IV" \
        --force >/dev/null 2>"${work}/err" || rc=$?
      cms_for_path="$GOOD_CMS"
      ;;
    --short-name)
      run_writer "$work" \
        --cms-id "$GOOD_CMS" \
        --parent-game-id "$GOOD_PARENT" \
        --title "Diablo IV" \
        --short-name "slug${INJECT}" \
        --force >/dev/null 2>"${work}/err" || rc=$?
      cms_for_path="$GOOD_CMS"
      ;;
    --app-store)
      run_writer "$work" \
        --cms-id "$GOOD_CMS" \
        --parent-game-id "$GOOD_PARENT" \
        --title "Diablo IV" \
        --app-store "STEAM${INJECT}" \
        --force >/dev/null 2>"${work}/err" || rc=$?
      cms_for_path="$GOOD_CMS"
      ;;
  esac
  assert_refused_no_file "$work" "$cms_for_path" "${field} newline+Exec=" "$rc"
  if grep -qi 'must match\|must be empty' "${work}/err"; then
    ok "${field} error mentions allowlist"
  else
    die "${field} error was not clear: $(cat "${work}/err")"
  fi
  rm -rf "$work"
done

# --- ID fields: CR, semicolon, %f, backticks, \$(...) ----------------------
id_junks=(
  $'102670811\r'
  'STEAM;evil'
  '%f'
  '`id`'
  '$(id)'
)
id_labels=(cr semicolon percent-f backticks 'dollar-paren')
for i in "${!id_junks[@]}"; do
  junk="${id_junks[$i]}"
  label="${id_labels[$i]}"
  work="$(new_work)"
  mkdir -p "${work}/tmp"
  rc=0
  run_writer "$work" \
    --cms-id "$GOOD_CMS" \
    --parent-game-id "$GOOD_PARENT" \
    --title "Diablo IV" \
    --app-store "$junk" \
    --force >/dev/null 2>"${work}/err" || rc=$?
  assert_refused_no_file "$work" "$GOOD_CMS" "--app-store ${label}" "$rc"
  rm -rf "$work"
done

# NUL cannot appear in bash argv (C strings). Reject other C0 in IDs.
work="$(new_work)"
mkdir -p "${work}/tmp"
rc=0
run_writer "$work" \
  --cms-id $'102670811\001' \
  --parent-game-id "$GOOD_PARENT" \
  --title "Diablo IV" \
  --force >/dev/null 2>"${work}/err" || rc=$?
assert_refused_no_file "$work" "102670811" "--cms-id NUL-adjacent C0" "$rc"
rm -rf "$work"

# --- free-text title: strip / escape, never a second Exec= -----------------
title_cases=(
  "newline:${INJECT}Diablo"
  $'cr:Diablo IV\rExec=touch /tmp/pwned'
  'semicolon:Diablo; IV'
  'percent:Diablo %f'
  'backticks:Diablo `reboot`'
  'dollar:Diablo $(touch /tmp/pwned)'
  $'combo:Diablo\nExec=touch /tmp/pwned;%f;`id`;$(id)'
)
for spec in "${title_cases[@]}"; do
  label="${spec%%:*}"
  title="${spec#*:}"
  work="$(new_work)"
  mkdir -p "${work}/tmp"
  rc=0
  run_writer "$work" \
    --cms-id "$GOOD_CMS" \
    --parent-game-id "$GOOD_PARENT" \
    --title "$title" \
    --short-name "" \
    --app-store "STEAM" \
    --force >/dev/null 2>"${work}/err" || rc=$?
  file="$(desktop_path "$work" "$GOOD_CMS")"
  if [[ "$rc" -ne 0 ]]; then
    # Refuse is acceptable for malicious free-text.
    assert_refused_no_file "$work" "$GOOD_CMS" "title ${label} refused" "$rc"
  else
    assert_safe_desktop "$file" "title ${label}"
    exec_line="$(grep '^Exec=' "$file")"
    if [[ "$exec_line" == *'%f'* && "$exec_line" != *'%%f'* ]]; then
      die "title ${label}: Exec contains unescaped %f"
    else
      ok "title ${label}: Exec has no raw %f field code"
    fi
  fi
  rm -rf "$work"
done

# --- box-art: normal image is resized; oversized header is refused ---------
if ! have_imagemagick; then
  die "ImageMagick (magick or convert) required for box-art decode tests"
else
  work="$(new_work)"
  mkdir -p "${work}/tmp"
  write_png "${work}/ok.png" 64 64 fill
  install_fake_curl "$work" "${work}/ok.png"
  rc=0
  run_writer "$work" \
    --cms-id "$GOOD_CMS" \
    --parent-game-id "$GOOD_PARENT" \
    --title "Diablo IV" \
    --box-art-url "https://img.example.test/ok.png" \
    --force >/dev/null 2>"${work}/err" || rc=$?
  file="$(desktop_path "$work" "$GOOD_CMS")"
  icon="$(icon_path "$work" "$GOOD_CMS")"
  assert_eq "normal box-art exit" "$rc" "0"
  assert_safe_desktop "$file" "normal box-art"
  if [[ -f "$icon" && -s "$icon" ]] && grep -q "^Icon=${icon}$" "$file"; then
    ok "normal box-art wrote icon"
  else
    die "normal box-art missing icon (${icon}): $(grep '^Icon=' "$file" 2>/dev/null || true)"
  fi
  rm -rf "$work"

  work="$(new_work)"
  mkdir -p "${work}/tmp"
  # 20k×20k in ~70 bytes: under distro 32KP policy, over our 4096 / 16MP cap.
  write_png "${work}/bomb.png" 20000 20000
  install_fake_curl "$work" "${work}/bomb.png"
  rc=0
  run_writer "$work" \
    --cms-id "$GOOD_CMS" \
    --parent-game-id "$GOOD_PARENT" \
    --title "Diablo IV" \
    --box-art-url "https://img.example.test/bomb.png" \
    --force >/dev/null 2>"${work}/err" || rc=$?
  file="$(desktop_path "$work" "$GOOD_CMS")"
  icon="$(icon_path "$work" "$GOOD_CMS")"
  assert_eq "oversize box-art exit" "$rc" "0"
  assert_safe_desktop "$file" "oversize box-art"
  if grep -q '^Icon=applications-games$' "$file"; then
    ok "oversize box-art fell back to default icon"
  else
    die "oversize box-art did not fall back: $(grep '^Icon=' "$file" || true)"
  fi
  if [[ -e "$icon" ]]; then
    die "oversize box-art wrote ${icon}"
  else
    ok "oversize box-art wrote no icon file"
  fi
  if grep -qi 'exceeds decode limits\|20000x20000' "${work}/err"; then
    ok "oversize box-art warned with dimensions"
  else
    die "oversize box-art warning missing dims: $(cat "${work}/err")"
  fi
  rm -rf "$work"
fi

# --- box-art URL injection is ignored; desktop still safe ------------------
work="$(new_work)"
mkdir -p "${work}/tmp"
rc=0
run_writer "$work" \
  --cms-id "$GOOD_CMS" \
  --parent-game-id "$GOOD_PARENT" \
  --title "Diablo IV" \
  --box-art-url $'https://example.com/x.png\nExec=touch /tmp/pwned' \
  --force >/dev/null 2>"${work}/err" || rc=$?
assert_eq "unsafe box-art url exit" "$rc" "0"
assert_safe_desktop "$(desktop_path "$work" "$GOOD_CMS")" "unsafe box-art url"
if grep -qi 'ignoring unsafe' "${work}/err"; then
  ok "unsafe box-art url warned"
else
  die "unsafe box-art url did not warn"
fi
rm -rf "$work"

# --- gfn-play.sh refuses injected ids (same class of bug) ------------------
PLAY="${ROOT}/scripts/gfn-play.sh"
work="$(new_work)"
rc=0
env -i PATH="$PATH" HOME="${work}/home" bash "$PLAY" \
  --cms-id "${GOOD_CMS}${INJECT}" \
  --parent-game-id "$GOOD_PARENT" \
  --title "Diablo IV" >/dev/null 2>"${work}/err" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -qi 'must match' "${work}/err"; then
  ok "gfn-play.sh refuses cmsId with newline+Exec="
else
  die "gfn-play.sh did not refuse injected cmsId (exit ${rc}): $(cat "${work}/err" 2>/dev/null || true)"
fi
rm -rf "$work"

# --- no leftover hidden temp dirs after success ----------------------------
work="$(new_work)"
mkdir -p "${work}/tmp"
run_writer "$work" \
  --cms-id "$GOOD_CMS" \
  --parent-game-id "$GOOD_PARENT" \
  --title "Diablo IV" \
  --force >/dev/null
leftovers="$(find "${work}/data/applications" -name '.gfn-write.*' 2>/dev/null || true)"
if [[ -z "$leftovers" ]]; then
  ok "no leftover .gfn-write temp dirs"
else
  die "leftover temp dirs: ${leftovers}"
fi
rm -rf "$work"

echo
echo "passed=${PASS} failed=${FAIL}"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
