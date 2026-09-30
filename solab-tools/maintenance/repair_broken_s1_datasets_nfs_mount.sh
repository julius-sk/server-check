#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Repair a broken or stale s1 datasets NFS mount on the affected client.
set -Eeuo pipefail
export LC_ALL=C

original_args=("$@")
target="${S1_NFS_DATASETS_TARGET:-/shared/datasets}"
expected_server="192.168.3.61"
mode="${1:-}"

if [[ "$mode" != "--apply" ]]; then
  echo "Usage: bash $0 --apply" >&2
  exit 2
fi
if [[ "$EUID" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo 'ERROR: sudo is required but is not installed or available in PATH' >&2
    exit 1
  }
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- env \
    S1_NFS_DATASETS_TARGET="${target}" \
    SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${script_path}" "${original_args[@]}"
fi
if [[ "$(hostname -s 2>/dev/null || hostname)" == "solab-s1" ]]; then
  echo "ERROR: refusing to run the NFS client repair on the s1 server" >&2
  exit 1
fi

run_user="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
run_home="$(getent passwd "$run_user" | cut -d: -f6)"
run_home="${run_home:-/root}"
run_uid="$(id -u "$run_user")"
run_gid="$(id -g "$run_user")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
state_root="${SOLAB_TOOLS_STATE_DIR:-${run_home}/.local/state/solab-tools}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_root="$(readlink -m -- "${state_root}")"
case "${state_root}" in
  "${repository_root}"|"${repository_root}"/*)
    echo "ERROR: run logs must stay outside the solab-tools checkout: ${state_root}" >&2
    exit 1
    ;;
esac
out_dir="${state_root}/${stamp}-repair-broken-s1-datasets-nfs-mount"

prepare_state_directory() {
  local default_state_root="${run_home}/.local/state/solab-tools"
  local directory

  if [[ "${EUID}" -eq 0 && "${run_user}" != root && "${state_root}" == "${default_state_root}" ]]; then
    for directory in "${run_home}/.local" "${run_home}/.local/state" "${default_state_root}"; do
      [[ ! -L "${directory}" ]] || {
        echo "ERROR: refusing to repair symlinked state directory: ${directory}" >&2
        exit 1
      }
      mkdir -p "${directory}"
      chown "${run_uid}:${run_gid}" "${directory}"
      chmod u+rwx "${directory}"
    done
    chown -R "${run_uid}:${run_gid}" "${default_state_root}"
  else
    mkdir -p "${state_root}"
  fi

  install -d -o "${run_uid}" -g "${run_gid}" -m 0700 "$out_dir"
}

prepare_state_directory
exec > >(tee -a "$out_dir/output.log") 2>&1

run() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

run_with_timeout() {
  local seconds="$1"
  shift
  run timeout --signal=TERM --kill-after=30s "${seconds}" "$@"
}

run_as_user_with_timeout() {
  local seconds="$1"
  shift
  if [[ "$run_user" == "root" ]]; then
    run_with_timeout "$seconds" "$@"
  else
    run_with_timeout "$seconds" sudo -H -u "$run_user" "$@"
  fi
}

echo "host=$(hostname)"
echo "time=$(date -Is)"
echo "run_user=${run_user}"
echo "target=${target}"
echo "expected_server=${expected_server}"

source_before="$(findmnt --mountpoint "$target" -n -o SOURCE 2>/dev/null | tail -n1 || true)"
fstype_before="$(findmnt --mountpoint "$target" -n -o FSTYPE 2>/dev/null | tail -n1 || true)"
fstab_source="$(findmnt --fstab --target "$target" -n -o SOURCE 2>/dev/null | tail -n1 || true)"
echo "source_before=${source_before}"
echo "fstype_before=${fstype_before}"
echo "fstab_source=${fstab_source}"
case "$source_before" in
  "${expected_server}:/shared/datasets"|"") ;;
  192.168.5.61:/shared/datasets)
    echo "ERROR: legacy 192.168.5.61 NFS mount detected; run step 05 to migrate it to 192.168.3.61" >&2
    exit 1
    ;;
  *)
    echo "ERROR: refusing to replace unexpected mount source ${source_before}" >&2
    exit 1
    ;;
esac
case "$fstab_source" in
  "${expected_server}:/shared/datasets"|"") ;;
  192.168.5.61:/shared/datasets)
    echo "ERROR: legacy 192.168.5.61 fstab entry detected; run step 05 to migrate it to 192.168.3.61" >&2
    exit 1
    ;;
  *)
    echo "ERROR: refusing to use unexpected fstab source ${fstab_source}" >&2
    exit 1
    ;;
esac

echo "===== verify fresh server export in a temporary mount ====="
probe_dir="$(mktemp -d /run/s1-datasets-repair-probe.XXXXXX)"
cleanup_probe() {
  if findmnt --mountpoint "$probe_dir" >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=30s 30 umount "$probe_dir" >/dev/null 2>&1 || true
  fi
  rmdir "$probe_dir" >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT
run_with_timeout 30 mount -t nfs4 \
  -o ro,vers=4.2,proto=tcp,timeo=20,retrans=1 \
  "${expected_server}:/shared/datasets" "$probe_dir"
run_with_timeout 15 stat -c '%d %i %A %n' "$probe_dir"
run_as_user_with_timeout 15 test -r "$probe_dir"
run_as_user_with_timeout 15 test -x "$probe_dir"
run_with_timeout 30 umount "$probe_dir"

echo "===== detach stale mount ====="
timeout --signal=TERM --kill-after=30s 120 \
  systemctl stop shared-datasets.automount shared-datasets.mount 2>/dev/null || true
if findmnt --mountpoint "$target" >/dev/null 2>&1; then
  if ! timeout --signal=TERM --kill-after=30s 30 umount -f "$target"; then
    echo "normal forced unmount did not finish; using lazy detach for stale NFS handle"
    run_with_timeout 30 umount -l "$target"
  fi
fi
if findmnt --mountpoint "$target" >/dev/null 2>&1; then
  echo "ERROR: ${target} is still mounted after detach" >&2
  exit 1
fi

echo "===== restore persistent mount ====="
run mkdir -p "$target"
run_with_timeout 120 systemctl daemon-reload
if systemctl list-unit-files shared-datasets.automount --no-legend 2>/dev/null | grep -q shared-datasets.automount; then
  run_with_timeout 120 systemctl start shared-datasets.automount
fi
run_with_timeout 45 mount "$target"
run findmnt --mountpoint "$target" -o TARGET,SOURCE,FSTYPE,OPTIONS

source_after="$(findmnt --mountpoint "$target" -n -o SOURCE)"
case "$source_after" in
  "${expected_server}:/shared/datasets") ;;
  *)
    echo "ERROR: repaired mount source is ${source_after}, expected s1" >&2
    exit 1
    ;;
esac

echo "===== verify fresh mount root and user write/delete access ====="
run_with_timeout 15 stat -c '%d %i %A %n' "$target"
run_as_user_with_timeout 15 test -r "$target"
run_as_user_with_timeout 15 test -x "$target"
run_as_user_with_timeout 60 env TEST_PARENT="$target" bash -c '
  set -Eeuo pipefail
  test_dir="$(mktemp -d -- "$TEST_PARENT/.solab-nfs-repair-write-test.XXXXXX")"
  test_file="$test_dir/probe"
  cleanup() {
    rm -f -- "$test_file" 2>/dev/null || true
    rmdir -- "$test_dir" 2>/dev/null || true
  }
  trap cleanup EXIT
  printf "%s %s\n" "$(hostname)" "$(date -Is)" >"$test_file"
  test -s "$test_file"
  rm -f -- "$test_file"
  rmdir -- "$test_dir"
  trap - EXIT
'

echo "SUMMARY_STATUS=PASS"
echo "SUMMARY_HOST=$(hostname)"
echo "SUMMARY_SOURCE_BEFORE=${source_before}"
echo "SUMMARY_SOURCE_AFTER=${source_after}"
echo "SUMMARY_MOUNT_ROOT=readable"
echo "SUMMARY_USER_WRITE_DELETE=pass"
echo "SUMMARY_LOG=${out_dir}/output.log"

if [[ "$run_user" != root ]]; then
  chown -R "${run_uid}:${run_gid}" "$out_dir" || true
fi
