#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Configure persistent client mounts for s1 models and datasets storage.
set -Eeuo pipefail
export LC_ALL=C

original_args=("$@")
mode="apply"

usage() {
  cat <<'EOF'
Usage:
  bash 05-setup-s1-shared-storage.sh
  bash 05-setup-s1-shared-storage.sh --check

Configure this client machine to mount s1 storage at:
  /shared/models   <- s1:/shared/models
  /shared/datasets <- s1:/shared/datasets

The script uses s1's stable 192.168.3.61 management address. It installs
nfs-common when needed, replaces only the two managed client mount entries in
/etc/fstab, mounts both paths, and verifies read access. Run it on every client
server; s1 already hosts these local paths. The default mode applies the
configuration; use --check for a read-only status report.

Safety overrides:
  ALLOW_NONEMPTY=1   Allow mounting over a non-empty local target directory.
  WRITE_TEST=1       Create and remove one client write-test file per mount.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      mode="check"
      ;;
    --apply)
      mode="apply"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

models_target="/shared/models"
datasets_target="/shared/datasets"
fstab_begin="# BEGIN s1 shared NFS client mounts"
fstab_end="# END s1 shared NFS client mounts"
mount_options="rw,_netdev,nofail,x-systemd.automount,vers=4.2,proto=tcp"
allow_nonempty="${ALLOW_NONEMPTY:-0}"
write_test="${WRITE_TEST:-0}"
probe_timeout="${PROBE_TIMEOUT_SECONDS:-15}"
operation_timeout=1200

section() {
  printf '\n===== %s =====\n' "$1"
}

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
  if [[ "${run_user}" == "root" ]]; then
    run_with_timeout "${seconds}" "$@"
  else
    run_with_timeout "${seconds}" sudo -H -u "${run_user}" "$@"
  fi
}

current_source() {
  findmnt --mountpoint "$1" -n -o SOURCE 2>/dev/null | tail -n1 || true
}

current_fstype() {
  findmnt --mountpoint "$1" -n -o FSTYPE 2>/dev/null | tail -n1 || true
}

check_mode() {
  local target source
  section "client identity and network"
  hostname || true
  date -Is || true
  id || true
  ip -brief address 2>/dev/null | grep -E '(^|[[:space:]])192\.168\.(3|5)\.' || true
  ip route get 192.168.3.61 2>&1 || true

  section "runtime mounts"
  for target in "${models_target}" "${datasets_target}"; do
    if findmnt --mountpoint "${target}" -o TARGET,SOURCE,FSTYPE,OPTIONS; then
      source="$(current_source "${target}")"
      case "${source}" in
        192.168.3.61:/shared/*)
          echo "S1_NFS_MOUNT_OK=${target}"
          ;;
        192.168.5.61:/shared/*)
          echo "LEGACY_UNSTABLE_S1_NFS_MOUNT=${target} source=${source}"
          ;;
        *)
          echo "NON_S1_MOUNT=${target} source=${source}"
          ;;
      esac
    else
      echo "UNMOUNTED=${target}"
    fi
  done

  section "persistent mounts"
  if [[ -r /etc/fstab ]]; then
    awk -v begin="${fstab_begin}" -v end="${fstab_end}" '
      $0 == begin {show=1}
      show {print}
      $0 == end {show=0}
    ' /etc/fstab
  fi
}

if [[ "${mode}" == "check" ]]; then
  check_mode
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo 'ERROR: sudo is required but is not installed or available in PATH' >&2
    exit 1
  }
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- env \
    ALLOW_NONEMPTY="${ALLOW_NONEMPTY:-0}" WRITE_TEST="${WRITE_TEST:-0}" \
    PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-15}" \
    ALLOW_ON_S1="${ALLOW_ON_S1:-0}" \
    SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${script_path}" "${original_args[@]}"
fi

if [[ "${ALLOW_ON_S1:-0}" != "1" ]]; then
  if [[ "$(hostname -s 2>/dev/null || hostname)" == "solab-s1" ]] \
    || ip -o -4 address 2>/dev/null | grep -Eq 'inet 192\.168\.(3|5)\.61/'; then
    echo "ERROR: this is s1 itself; refusing to configure s1 as its own NFS client" >&2
    exit 1
  fi
fi

run_user="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
run_home="$(getent passwd "$run_user" | cut -d: -f6)"
run_home="${run_home:-/root}"
run_uid="$(id -u "${run_user}")"
run_gid="$(id -g "${run_user}")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
state_root="${SOLAB_TOOLS_STATE_DIR:-${run_home}/.local/state/solab-tools}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
state_root="$(readlink -m -- "${state_root}")"
case "${state_root}" in
  "${repository_root}"|"${repository_root}"/*)
    echo "ERROR: run logs must stay outside the solab-tools checkout: ${state_root}" >&2
    exit 1
    ;;
esac
out_dir="${state_root}/${stamp}-setup-s1-shared-storage"

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

  install -d -o "${run_uid}" -g "${run_gid}" -m 0700 "${out_dir}"
}

prepare_state_directory
exec > >(tee -a "${out_dir}/output.log") 2>&1

section "start"
hostname
date -Is
echo "run_user=${run_user}"
echo "out_dir=${out_dir}"

section "install NFS client"
if ! dpkg-query -W -f='${Status}' nfs-common 2>/dev/null | grep -Fq 'install ok installed'; then
  run_with_timeout "${operation_timeout}" apt-get update
  run_with_timeout "${operation_timeout}" env DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common
else
  echo "nfs-common already installed"
fi

target_is_safe() {
  local target="$1" source fstype
  if findmnt --mountpoint "${target}" >/dev/null 2>&1; then
    source="$(current_source "${target}")"
    fstype="$(current_fstype "${target}")"
    case "${source}" in
      192.168.5.61:/shared/*|192.168.3.61:/shared/*)
        echo "${target} is already mounted from s1 (${source}, ${fstype})"
        return 0
        ;;
      *)
        echo "ERROR: ${target} is already a non-s1 mount (${source}, ${fstype})" >&2
        return 1
        ;;
    esac
  fi

  if [[ -d "${target}" ]] && find "${target}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    if [[ "${allow_nonempty}" != "1" ]]; then
      echo "ERROR: ${target} is a non-empty local directory; set ALLOW_NONEMPTY=1 only if hiding it is intentional" >&2
      return 1
    fi
    echo "WARNING: mounting over non-empty local directory ${target}"
  fi
}

target_is_safe "${models_target}"
target_is_safe "${datasets_target}"

declare -a candidates=(192.168.3.61)

probe_dir="$(mktemp -d /run/s1-nfs-probe.XXXXXX)"
cleanup_probe() {
  if findmnt --mountpoint "${probe_dir}" >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=30s 30 umount "${probe_dir}" >/dev/null 2>&1 || true
  fi
  rmdir "${probe_dir}" >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT

selected_server=""
section "select reachable s1 NFS address"
for candidate in "${candidates[@]}"; do
  echo "Probing ${candidate}:/shared/models"
  if timeout --signal=TERM --kill-after=30s "${probe_timeout}" mount -t nfs4 \
    -o ro,vers=4.2,proto=tcp,timeo=20,retrans=1 \
    "${candidate}:/shared/models" "${probe_dir}"; then
    run_with_timeout 15 stat -c '%d %i %A %n' "${probe_dir}"
    run_as_user_with_timeout 15 test -r "${probe_dir}"
    run_as_user_with_timeout 15 test -x "${probe_dir}"
    run_with_timeout 30 umount "${probe_dir}"
    selected_server="${candidate}"
    break
  fi
  timeout --signal=TERM --kill-after=30s 30 umount "${probe_dir}" >/dev/null 2>&1 || true
done

if [[ -z "${selected_server}" ]]; then
  echo "ERROR: none of the s1 NFS addresses accepted a test mount: ${candidates[*]}" >&2
  exit 1
fi
echo "SELECTED_SERVER=${selected_server}"

section "prepare mountpoints"
run mkdir -p "${models_target}" "${datasets_target}"

section "write persistent client mounts"
run cp -a /etc/fstab "${out_dir}/fstab.before"
fstab_tmp="$(mktemp)"
awk -v begin="${fstab_begin}" -v end="${fstab_end}" \
  -v models="${models_target}" -v datasets="${datasets_target}" '
  $0 == begin {skip=1; next}
  $0 == end {skip=0; next}
  skip {next}
  $0 !~ /^[[:space:]]*#/ && ($2 == models || $2 == datasets) {next}
  {print}
' /etc/fstab >"${fstab_tmp}"
{
  cat "${fstab_tmp}"
  printf '%s\n' "${fstab_begin}"
  printf '%s:/shared/models %s nfs4 %s 0 0\n' \
    "${selected_server}" "${models_target}" "${mount_options}"
  printf '%s:/shared/datasets %s nfs4 %s 0 0\n' \
    "${selected_server}" "${datasets_target}" "${mount_options}"
  printf '%s\n' "${fstab_end}"
} >/etc/fstab
rm -f "${fstab_tmp}"
run systemctl daemon-reload
run findmnt --verify --verbose --tab-file /etc/fstab || \
  echo "WARNING: findmnt reported a non-target fstab issue; target checks continue below"

section "mount"
for target in "${models_target}" "${datasets_target}"; do
  expected="${selected_server}:${target}"
  source="$(current_source "${target}")"
  if [[ -n "${source}" && "${source}" != "${expected}" ]]; then
    run_with_timeout 30 umount "${target}"
  fi
  if ! findmnt --mountpoint "${target}" >/dev/null 2>&1; then
    run_with_timeout 30 mount "${target}"
  fi
  run findmnt --mountpoint "${target}" -o TARGET,SOURCE,FSTYPE,OPTIONS
  source="$(current_source "${target}")"
  [[ "${source}" == "${expected}" ]] || {
    echo "ERROR: ${target} mounted from ${source}, expected ${expected}" >&2
    exit 1
  }
  run_with_timeout 15 stat -c '%d %i %A %n' "${target}"
  run_as_user_with_timeout 15 test -r "${target}"
  run_as_user_with_timeout 15 test -x "${target}"
done

if [[ "${write_test}" == "1" ]]; then
  section "write test"
  for target in "${models_target}" "${datasets_target}"; do
    run_as_user_with_timeout 60 env TEST_PARENT="${target}" bash -c '
      set -Eeuo pipefail
      test_dir="$(mktemp -d -- "$TEST_PARENT/.solab-nfs-client-write-test.XXXXXX")"
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
  done
fi

section "summary"
echo "SUMMARY_STATUS=PASS"
echo "SUMMARY_SERVER=${selected_server}"
echo "SUMMARY_MOUNTS=${models_target},${datasets_target}"
echo "SUMMARY_FSTAB=/etc/fstab"
echo "SUMMARY_LOG=${out_dir}/output.log"

if [[ "${run_user}" != root ]]; then
  chown -R "${run_uid}:${run_gid}" "${out_dir}" || true
fi
