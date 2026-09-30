#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Deduplicate identical files on Btrfs with the jdupes same-extents operation.
set -Eeuo pipefail
export LC_ALL=C

original_args=("$@")
apply=0
declare -a targets=()

usage() {
  cat <<'EOF'
Usage:
  bash maintenance/deduplicate_btrfs_files_with_jdupes.sh BTRFS_PATH [BTRFS_PATH...]
  bash maintenance/deduplicate_btrfs_files_with_jdupes.sh --apply BTRFS_PATH [BTRFS_PATH...]

Default mode validates the paths and prints the planned jdupes command. Apply
mode recursively finds byte-identical files and asks Btrfs to share their data
extents with the filesystem dedupe ioctl.

The command uses jdupes -r -1 -B. It does not delete files, create hard links,
follow symbolic links, or merge matches across different filesystems. Stop
writers before a large dedupe run and keep a current backup.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        targets+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      targets+=("$1")
      ;;
  esac
  shift
done

[[ "${#targets[@]}" -gt 0 ]] || {
  echo 'ERROR: provide at least one Btrfs directory' >&2
  usage >&2
  exit 2
}
if [[ "${apply}" -eq 1 && "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo 'ERROR: sudo is required but is not installed or available in PATH' >&2
    exit 1
  }
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- env SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${script_path}" "${original_args[@]}"
fi
command -v findmnt >/dev/null 2>&1 || {
  echo 'ERROR: findmnt is required' >&2
  exit 127
}
command -v jdupes >/dev/null 2>&1 || {
  echo 'ERROR: jdupes is required; install the distribution jdupes package first' >&2
  exit 127
}
if ! jdupes --help 2>&1 | grep -Eq -- '(^|[[:space:]])-B([,[:space:]]|$)|--dedupe'; then
  echo 'ERROR: this jdupes build does not provide Btrfs --dedupe support' >&2
  exit 1
fi

declare -a resolved_targets=()
declare -A seen_targets=()
for target in "${targets[@]}"; do
  [[ -d "${target}" ]] || {
    echo "ERROR: target is not a directory: ${target}" >&2
    exit 1
  }
  resolved="$(readlink -f -- "${target}")"
  [[ -n "${resolved}" && "${resolved}" == /* ]] || {
    echo "ERROR: could not resolve target: ${target}" >&2
    exit 1
  }
  fstype="$(findmnt -T "${resolved}" -n -o FSTYPE | tail -n 1)"
  source="$(findmnt -T "${resolved}" -n -o SOURCE | tail -n 1)"
  [[ "${fstype}" == btrfs ]] || {
    echo "ERROR: ${resolved} is on ${fstype:-unknown}, not Btrfs" >&2
    exit 1
  }
  if [[ -n "${seen_targets[${resolved}]:-}" ]]; then
    echo "DUPLICATE_TARGET_SKIPPED=${resolved}"
    continue
  fi
  seen_targets["${resolved}"]=1
  echo "TARGET=${resolved} SOURCE=${source} FSTYPE=${fstype}"
  resolved_targets+=("${resolved}")
done

printf 'COMMAND='
printf ' %q' jdupes -r -1 -B "${resolved_targets[@]}"
printf '\n'
if [[ "${apply}" -ne 1 ]]; then
  echo 'PLAN_ONLY=1'
  printf 'NEXT_COMMAND='
  printf ' %q' bash "$0" --apply "${resolved_targets[@]}"
  printf '\n'
  echo 'NOTE=apply mode requests sudo authentication automatically'
  exit 0
fi

caller_user="${SUDO_USER:-root}"
caller_home="$(getent passwd "${caller_user}" 2>/dev/null | cut -d: -f6)"
caller_home="${caller_home:-/root}"
caller_uid="$(id -u "${caller_user}")"
caller_gid="$(id -g "${caller_user}")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
state_root="${SOLAB_TOOLS_STATE_DIR:-${caller_home}/.local/state/solab-tools}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_root="$(readlink -m -- "${state_root}")"
case "${state_root}" in
  "${repository_root}"|"${repository_root}"/*)
    echo "ERROR: run logs must stay outside the solab-tools checkout: ${state_root}" >&2
    exit 1
    ;;
esac
out_dir="${state_root}/${stamp}-deduplicate-btrfs-with-jdupes"

prepare_state_directory() {
  local default_state_root="${caller_home}/.local/state/solab-tools"
  local directory

  if [[ "${EUID}" -eq 0 && "${caller_user}" != root && "${state_root}" == "${default_state_root}" ]]; then
    for directory in "${caller_home}/.local" "${caller_home}/.local/state" "${default_state_root}"; do
      [[ ! -L "${directory}" ]] || {
        echo "ERROR: refusing to repair symlinked state directory: ${directory}" >&2
        exit 1
      }
      mkdir -p "${directory}"
      chown "${caller_uid}:${caller_gid}" "${directory}"
      chmod u+rwx "${directory}"
    done
    chown -R "${caller_uid}:${caller_gid}" "${default_state_root}"
  else
    mkdir -p "${state_root}"
  fi

  install -d -o "${caller_uid}" -g "${caller_gid}" -m 0700 "${out_dir}"
}

prepare_state_directory
exec > >(tee -a "${out_dir}/output.log") 2>&1

echo "BEGIN=$(date -Is)"
jdupes --version || true
jdupes -r -1 -B "${resolved_targets[@]}"
echo "END=$(date -Is)"
echo 'BTRFS_JDUPES_DEDUP_OK=1'
echo "LOG=${out_dir}/output.log"
if [[ "${caller_user}" != root ]]; then
  chown -R "${caller_uid}:${caller_gid}" "${out_dir}" || true
fi
