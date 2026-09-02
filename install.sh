#!/usr/bin/env bash

set -euo pipefail

SKILL_NAME="keylink-image"
ARCHIVE_URL="${KEYLINK_IMAGE_SKILL_ARCHIVE_URL:-https://github.com/Tilmirs/keylink-codex-image/archive/refs/heads/main.tar.gz}"
PROXY_URL="${KEYLINK_IMAGE_PROXY_URL:-${HTTPS_PROXY:-${HTTP_PROXY:-${ALL_PROXY:-}}}}"
SOURCE_ROOT=""
DOWNLOAD_ROOT=""
STAGING_PATH=""
SKILLS_ROOT=""
REMOTE_UPDATE=0

usage() {
  printf 'Usage: %s [--source PATH] [--remote] [--archive-url URL] [--proxy-url URL]\n' "${0##*/}"
}

safe_remove_temp_dir() {
  local target="$1"
  local expected_parent="$2"
  local expected_prefix="$3"
  local resolved_parent
  local resolved_expected_parent
  local target_name

  if [[ -z "$target" || ! -d "$target" || -z "$expected_parent" ]]; then
    return
  fi

  resolved_parent="$(cd -- "$(dirname "$target")" && pwd -P)"
  resolved_expected_parent="$(cd -- "$expected_parent" && pwd -P)"
  target_name="${target##*/}"
  if [[ "$resolved_parent" == "$resolved_expected_parent" && "$target_name" == "$expected_prefix"* ]]; then
    rm -rf "$target"
  else
    printf 'Refusing to remove unexpected temporary directory: %s\n' "$target" >&2
  fi
}

cleanup() {
  safe_remove_temp_dir "$STAGING_PATH" "$SKILLS_ROOT" ".keylink-image.install."
  safe_remove_temp_dir "$DOWNLOAD_ROOT" "${TMPDIR:-/tmp}" "keylink-image-source."
}

trap cleanup EXIT

validate_skill_folder() {
  local root="$1"
  local relative_path
  local frontmatter

  for relative_path in \
    "SKILL.md" \
    "agents/openai.yaml" \
    "install.ps1" \
    "install.sh" \
    "scripts/generate_image.js" \
    "scripts/keylink_common.js" \
    "scripts/list_image_models.js" \
    "scripts/generate_image.ps1" \
    "scripts/list_image_models.ps1" \
    "scripts/read_ccswitch_credential.js" \
    "references/api.md" \
    "references/troubleshooting.md"; do
    if [[ ! -f "$root/$relative_path" ]]; then
      printf 'Skill package is incomplete. Missing: %s\n' "$relative_path" >&2
      return 1
    fi
  done

  frontmatter="$(awk '
    NR == 1 {
      sub(/\r$/, "")
      if ($0 != "---") {
        status = 2
        exit
      }
      next
    }
    {
      sub(/\r$/, "")
      if ($0 == "---") {
        closed = 1
        exit
      }
      print
    }
    END {
      if (status) exit status
      if (!closed) exit 3
    }
  ' "$root/SKILL.md")" || {
    printf 'SKILL.md does not contain valid YAML frontmatter.\n' >&2
    return 1
  }

  if ! printf '%s\n' "$frontmatter" | grep -Eq '^name:[[:space:]]*keylink-image[[:space:]]*$'; then
    printf 'SKILL.md frontmatter must declare name: keylink-image.\n' >&2
    return 1
  fi
}

download_source() {
  local archive_path
  local extracted_root

  command -v curl >/dev/null 2>&1 || {
    printf 'curl is required for remote installation.\n' >&2
    exit 1
  }
  command -v tar >/dev/null 2>&1 || {
    printf 'tar is required for remote installation.\n' >&2
    exit 1
  }

  DOWNLOAD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/keylink-image-source.XXXXXX")"
  archive_path="$DOWNLOAD_ROOT/source.tar.gz"
  if [[ -n "$PROXY_URL" ]]; then
    curl -fsSL --proxy "$PROXY_URL" "$ARCHIVE_URL" -o "$archive_path"
  else
    curl -fsSL "$ARCHIVE_URL" -o "$archive_path"
  fi
  tar -xzf "$archive_path" -C "$DOWNLOAD_ROOT"

  extracted_root=""
  extracted_count=0
  for candidate in "$DOWNLOAD_ROOT"/*; do
    if [[ -d "$candidate" ]]; then
      extracted_count=$((extracted_count + 1))
      extracted_root="$candidate"
    fi
  done
  if [[ "$extracted_count" -ne 1 || -z "$extracted_root" ]]; then
    printf 'The downloaded archive must contain exactly one skill directory.\n' >&2
    exit 1
  fi
  SOURCE_ROOT="$extracted_root"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      SOURCE_ROOT="$2"
      shift 2
      ;;
    --remote)
      SOURCE_ROOT=""
      REMOTE_UPDATE=1
      shift
      ;;
    --archive-url)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      ARCHIVE_URL="$2"
      shift 2
      ;;
    --proxy-url)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      PROXY_URL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$REMOTE_UPDATE" -eq 0 && -z "$SOURCE_ROOT" && -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  candidate_root="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if [[ -f "$candidate_root/SKILL.md" ]]; then
    SOURCE_ROOT="$candidate_root"
  fi
fi

if [[ -z "$SOURCE_ROOT" ]]; then
  download_source
fi

if [[ ! -d "$SOURCE_ROOT" ]]; then
  printf 'Skill source directory does not exist: %s\n' "$SOURCE_ROOT" >&2
  exit 1
fi
SOURCE_ROOT="$(cd -- "$SOURCE_ROOT" && pwd -P)"
validate_skill_folder "$SOURCE_ROOT"

if [[ -n "${CODEX_HOME:-}" ]]; then
  codex_home="$CODEX_HOME"
else
  if [[ -z "${HOME:-}" ]]; then
    printf 'Neither CODEX_HOME nor HOME is available.\n' >&2
    exit 1
  fi
  codex_home="$HOME/.codex"
fi

mkdir -p "$codex_home"
codex_home="$(cd -- "$codex_home" && pwd -P)"
SKILLS_ROOT="$codex_home/skills"
destination="$SKILLS_ROOT/$SKILL_NAME"
mkdir -p "$SKILLS_ROOT"
SKILLS_ROOT="$(cd -- "$SKILLS_ROOT" && pwd -P)"
destination="$SKILLS_ROOT/$SKILL_NAME"

if [[ "$SOURCE_ROOT" == "$destination" ]]; then
  printf 'The source package is already the installed destination. Use --remote to update from GitHub.\n' >&2
  exit 1
fi

STAGING_PATH="$(mktemp -d "$SKILLS_ROOT/.keylink-image.install.XXXXXX")"
cp "$SOURCE_ROOT/SKILL.md" "$STAGING_PATH/"
cp "$SOURCE_ROOT/install.ps1" "$STAGING_PATH/install.ps1"
cp "$SOURCE_ROOT/install.sh" "$STAGING_PATH/install.sh"
cp -R "$SOURCE_ROOT/agents" "$STAGING_PATH/agents"
cp -R "$SOURCE_ROOT/scripts" "$STAGING_PATH/scripts"
cp -R "$SOURCE_ROOT/references" "$STAGING_PATH/references"
validate_skill_folder "$STAGING_PATH"

backup_path=""
if [[ -e "$destination" ]]; then
  if [[ ! -d "$destination" ]]; then
    printf 'Install destination exists but is not a directory: %s\n' "$destination" >&2
    exit 1
  fi

  backup_root="$codex_home/skill-backups/$SKILL_NAME"
  mkdir -p "$backup_root"
  backup_path="$backup_root/$(date -u '+%Y%m%d-%H%M%S')-$$"
  suffix=0
  while [[ -e "$backup_path" ]]; do
    suffix=$((suffix + 1))
    backup_path="$backup_root/$(date -u '+%Y%m%d-%H%M%S')-$$-$suffix"
  done
  mv "$destination" "$backup_path"
fi

if ! mv "$STAGING_PATH" "$destination"; then
  if [[ -n "$backup_path" && -d "$backup_path" && ! -e "$destination" ]]; then
    mv "$backup_path" "$destination"
    backup_path=""
  fi
  printf 'Installation failed while activating the new skill.\n' >&2
  exit 1
fi
STAGING_PATH=""

printf 'Keylink Image installed: %s\n' "$destination"
if [[ -n "$backup_path" ]]; then
  printf 'Previous version backed up: %s\n' "$backup_path"
fi
printf 'The skill will be available to Codex on the next turn; restart Codex if it is not discovered.\n'
