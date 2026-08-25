#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
installer="$repo_root/install.sh"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/keylink-image-install-test.XXXXXX")"

cleanup() {
  local temp_parent
  local temp_name

  temp_parent="$(cd -- "$(dirname "$temp_root")" && pwd -P)"
  temp_name="${temp_root##*/}"
  if [[ "$temp_parent" == "$(cd -- "${TMPDIR:-/tmp}" && pwd -P)" && "$temp_name" == keylink-image-install-test.* ]]; then
    rm -rf "$temp_root"
  fi
}

trap cleanup EXIT

assert_file() {
  if [[ ! -f "$1" ]]; then
    printf 'Assertion failed: missing file %s\n' "$1" >&2
    exit 1
  fi
}

assert_text() {
  local expected="$1"
  local path="$2"
  if [[ "$(cat "$path")" != "$expected" ]]; then
    printf 'Assertion failed: unexpected content in %s\n' "$path" >&2
    exit 1
  fi
}

export CODEX_HOME="$temp_root/codex-home"
destination="$CODEX_HOME/skills/keylink-image"
credential_path="$CODEX_HOME/secrets/keylink-image-api-key.txt"
external_sentinel="$temp_root/unrelated-directory/keep.txt"

mkdir -p "$(dirname "$credential_path")" "$(dirname "$external_sentinel")"
printf 'not-a-real-key' > "$credential_path"
printf 'do-not-change' > "$external_sentinel"

bash "$installer" --source "$repo_root"
assert_file "$destination/SKILL.md"
assert_file "$destination/scripts/generate_image.js"
assert_file "$destination/scripts/generate_image.ps1"

printf 'old-version' > "$destination/old-version-marker.txt"
bash "$installer" --source "$repo_root"

backup_marker=""
for marker in "$CODEX_HOME"/skill-backups/keylink-image/*/old-version-marker.txt; do
  if [[ -f "$marker" ]]; then
    backup_marker="$marker"
    break
  fi
done
if [[ -z "$backup_marker" ]]; then
  printf 'Assertion failed: update did not preserve the old installation.\n' >&2
  exit 1
fi
if [[ -e "$destination/old-version-marker.txt" ]]; then
  printf 'Assertion failed: update did not replace old files.\n' >&2
  exit 1
fi

assert_text 'not-a-real-key' "$credential_path"
assert_text 'do-not-change' "$external_sentinel"

archive_parent="$temp_root/archive"
archive_skill="$archive_parent/keylink-codex-image-main"
archive_path="$temp_root/keylink-codex-image-main.tar.gz"
remote_codex_home="$temp_root/remote-codex-home"
archive_url="file://$archive_path"
mkdir -p "$archive_skill"
cp "$repo_root/SKILL.md" "$archive_skill/"
cp -R "$repo_root/agents" "$archive_skill/agents"
cp -R "$repo_root/scripts" "$archive_skill/scripts"
cp -R "$repo_root/references" "$archive_skill/references"
tar -czf "$archive_path" -C "$archive_parent" keylink-codex-image-main

if command -v cygpath >/dev/null 2>&1; then
  archive_url="file:///$(cygpath -am "$archive_path")"
fi

CODEX_HOME="$remote_codex_home" \
KEYLINK_IMAGE_SKILL_ARCHIVE_URL="$archive_url" \
bash -s < "$installer"
assert_file "$remote_codex_home/skills/keylink-image/SKILL.md"
assert_file "$remote_codex_home/skills/keylink-image/scripts/generate_image.js"
assert_file "$remote_codex_home/skills/keylink-image/scripts/generate_image.ps1"

printf 'All Keylink macOS/Linux installer tests passed.\n'
