#!/usr/bin/env bash
# Safely merge this plugin's sample Games menu rows into the user's Omarchy
# menu extension file. Omarchy does NOT auto-inject menu JSONC on plugin add.
#
# Usage:
#   install-menu-extension.sh [--dry-run] [--source PATH] [--target PATH]
#
# Defaults:
#   --source  <plugin-or-repo>/extensions/omarchy-menu.jsonc
#   --target  ~/.config/omarchy/extensions/omarchy-menu.jsonc
#
# Behavior:
#   - Idempotent: managed BEGIN/END block is replaced in place, or the merge
#     is skipped when the sample keys are already present without markers.
#   - Never wipes the user file; only inserts/updates a marked block.
#   - Backs up the target to *.bak.<timestamp> before any write.
#   - --dry-run prints the planned action and would-be contents; no writes.

set -euo pipefail

PLUGIN_ID="matt-dance.gfn"
BEGIN_MARK="// BEGIN ${PLUGIN_ID}"
END_MARK="// END ${PLUGIN_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE=""
TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
DRY_RUN=0

usage() {
  sed -n '2,18p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SOURCE" ]]; then
  SOURCE="${REPO_ROOT}/extensions/omarchy-menu.jsonc"
fi

die() {
  echo "error: $*" >&2
  exit 1
}

if [[ ! -f "$SOURCE" ]]; then
  die "sample menu extension not found: ${SOURCE}
Expected the plugin sample at extensions/omarchy-menu.jsonc (repo checkout or
~/.config/omarchy/plugins/${PLUGIN_ID}/extensions/omarchy-menu.jsonc).
Pass --source PATH if it lives elsewhere."
fi

# Extract the JSON object body (keys only) from the sample, dropping the
# leading comment banner. Keeps nested braces and inner // comments intact.
extract_sample_body() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"

  # Drop leading // comment lines and blanks before the object.
  awk '
    BEGIN { seen = 0 }
    /^[[:space:]]*\/\// { if (!seen) next }
    /^[[:space:]]*$/ { if (!seen) next }
    { seen = 1; print }
  ' "$file" >"$tmp"

  local first last
  first="$(head -n 1 "$tmp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  last="$(tail -n 1 "$tmp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$first" != "{" ]] || [[ "$last" != "}" ]]; then
    rm -f "$tmp"
    die "sample menu JSONC must be a single top-level object: ${file}"
  fi

  # Body = everything between first and last line; drop full-line //
  # comments and blank lines so the managed block is just the keys.
  # Keep // gfn-games:* markers — sync-menu-games.sh rewrites that region.
  sed '1d;$d' "$tmp" | awk '
    /^[[:space:]]*\/\/ gfn-games:/ { print; next }
    /^[[:space:]]*\/\// { next }
    /^[[:space:]]*$/ { next }
    { print }
  '
  rm -f "$tmp"
}

# Keys we consider "already present" for the skip-without-markers path.
SAMPLE_KEYS=("gaming.geforce-now.search" "games.gfn-search")

keys_already_present() {
  local file="$1"
  local key
  for key in "${SAMPLE_KEYS[@]}"; do
    if grep -Eq "\"${key}\"[[:space:]]*:" "$file"; then
      return 0
    fi
  done
  return 1
}

has_managed_block() {
  local file="$1"
  grep -Fq "$BEGIN_MARK" "$file" && grep -Fq "$END_MARK" "$file"
}

# Build the managed block text (no surrounding commas).
build_managed_block() {
  local body="$1"
  # Trim leading/trailing blank lines from body.
  body="$(printf '%s\n' "$body" | sed -e '/./,$!d')"
  while [[ "$body" == *$'\n' ]]; do
    body="${body%$'\n'}"
  done
  printf '  %s\n' "$BEGIN_MARK"
  printf '%s\n' "$body"
  printf '  %s\n' "$END_MARK"
}

# Replace an existing managed block in place; keep surrounding user content.
replace_managed_block() {
  local file="$1"
  local block="$2"
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v block="$block" '
    BEGIN { in_block = 0; replaced = 0 }
    index($0, begin) {
      if (!replaced) {
        print block
        replaced = 1
      }
      in_block = 1
      next
    }
    in_block {
      if (index($0, end)) {
        in_block = 0
      }
      next
    }
    { print }
    END {
      if (!replaced) exit 2
    }
  ' "$file"
}

# Ensure the last significant (non-blank, non-//) line before a position ends
# with a comma when it looks like a JSON property/value.
ensure_trailing_comma() {
  local file="$1"
  local sig_nr
  sig_nr="$(awk '
    {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*\/\//) next
      n = NR
      text = $0
    }
    END {
      if (!n) exit 0
      gsub(/[[:space:]]+$/, "", text)
      if (text == "{" || text ~ /,$/) exit 0
      print n
    }
  ' "$file")"
  if [[ -n "${sig_nr:-}" ]]; then
    # Portable in-place: rewrite via temp (avoid GNU/BSD sed -i differences).
    local tmp
    tmp="$(mktemp)"
    awk -v n="$sig_nr" 'NR == n { sub(/[[:space:]]*$/, ","); print; next } { print }' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
  fi
}

# Insert managed block before the final closing } of a JSONC object.
merge_into_object() {
  local file="$1"
  local block="$2"
  local content
  content="$(cat "$file")"

  # Empty / whitespace-only → write a fresh object.
  if [[ -z "${content//[[:space:]]/}" ]]; then
    printf '{\n%s\n}\n' "$block"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" >"$tmp"

  local last_nr
  last_nr="$(awk 'NF { n=NR } END { print n+0 }' "$tmp")"
  if [[ "$last_nr" -eq 0 ]]; then
    rm -f "$tmp"
    printf '{\n%s\n}\n' "$block"
    return
  fi

  local last_line
  last_line="$(sed -n "${last_nr}p" "$tmp" | sed 's/[[:space:]]*$//')"
  if [[ "$last_line" != "}" ]]; then
    rm -f "$tmp"
    die "refusing to merge: ${file} does not end with a top-level closing '}'
Fix or recreate the file, then re-run. Broken user JSONC silently drops all
user extension rows."
  fi

  local before_tmp
  before_tmp="$(mktemp)"
  if [[ "$last_nr" -eq 1 ]]; then
    : >"$before_tmp"
  else
    sed -n "1,$((last_nr - 1))p" "$tmp" >"$before_tmp"
  fi
  rm -f "$tmp"

  # Trim trailing blank lines.
  local trimmed_before
  trimmed_before="$(awk '
    { lines[NR] = $0 }
    END {
      end = NR
      while (end > 0 && lines[end] ~ /^[[:space:]]*$/) end--
      for (i = 1; i <= end; i++) print lines[i]
    }
  ' "$before_tmp")"
  printf '%s\n' "$trimmed_before" >"$before_tmp"

  # Effectively empty or only "{" → fresh object with the block.
  local stripped
  stripped="$(tr -d '[:space:]' <"$before_tmp")"
  if [[ -z "$stripped" || "$stripped" == "{" ]]; then
    rm -f "$before_tmp"
    printf '{\n%s\n}\n' "$block"
    return
  fi

  ensure_trailing_comma "$before_tmp"

  cat "$before_tmp"
  printf '%s\n' "$block"
  printf '}\n'
  rm -f "$before_tmp"
}

write_target() {
  local dest="$1"
  local data="$2"
  local parent
  parent="$(dirname "$dest")"

  if [[ ! -d "$parent" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "dry-run: would create directory: ${parent}"
    else
      mkdir -p "$parent" || die "could not create directory: ${parent}"
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "dry-run: would write: ${dest}"
    echo "----- begin preview -----"
    printf '%s' "$data"
    if [[ "$data" != *$'\n' ]]; then
      printf '\n'
    fi
    echo "----- end preview -----"
    return
  fi

  if [[ -e "$dest" ]]; then
    local backup
    backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$dest" "$backup" || die "could not backup ${dest} → ${backup}"
    echo "backup: ${backup}"
  fi

  local out
  out="$(mktemp)"
  printf '%s' "$data" >"$out"
  if [[ -s "$out" ]] && [[ "$(tail -c 1 "$out" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$out"
  fi
  mv "$out" "$dest"
  echo "wrote: ${dest}"
}

SAMPLE_BODY="$(extract_sample_body "$SOURCE")"
if [[ -z "${SAMPLE_BODY//[[:space:]]/}" ]]; then
  die "sample menu extension has no keys to merge: ${SOURCE}"
fi

MANAGED_BLOCK="$(build_managed_block "$SAMPLE_BODY")"

echo "source: ${SOURCE}"
echo "target: ${TARGET}"

if [[ -f "$TARGET" ]]; then
  if has_managed_block "$TARGET"; then
    echo "status: updating existing managed block (${PLUGIN_ID})"
    NEW_CONTENT="$(replace_managed_block "$TARGET" "$MANAGED_BLOCK")"
    write_target "$TARGET" "$NEW_CONTENT"
  elif keys_already_present "$TARGET"; then
    echo "status: skip — sample keys already present in ${TARGET}"
    echo "hint: remove those keys (or add ${BEGIN_MARK} / ${END_MARK} around them) to let this script manage the block."
    exit 0
  else
    echo "status: merging managed block into existing file"
    NEW_CONTENT="$(merge_into_object "$TARGET" "$MANAGED_BLOCK")"
    write_target "$TARGET" "$NEW_CONTENT"
  fi
else
  OMARCHY_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
  case "$TARGET" in
    "$OMARCHY_ROOT"/*)
      if [[ ! -d "$OMARCHY_ROOT" ]]; then
        echo "warning: Omarchy config dir not found (${OMARCHY_ROOT})." >&2
        echo "warning: creating target path anyway; install Omarchy before expecting the menu to load." >&2
      fi
      ;;
  esac
  echo "status: creating new extension file with managed block"
  NEW_CONTENT="$(printf '{\n%s\n}\n' "$MANAGED_BLOCK")"
  write_target "$TARGET" "$NEW_CONTENT"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "next: run  omarchy menu refresh  (on an Omarchy host)"
fi
