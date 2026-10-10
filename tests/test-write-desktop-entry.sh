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
    PATH="$PATH" \
    HOME="${work}/home" \
    XDG_DATA_HOME="${work}/data" \
    XDG_CONFIG_HOME="${work}/config" \
    TMPDIR="${work}/tmp" \
    bash "$WRITER" "$@"
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
rm -rf "$work"

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
