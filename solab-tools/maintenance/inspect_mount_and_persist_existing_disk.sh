#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Detect, inspect, mount, and persist existing filesystems without formatting.
set -Eeuo pipefail
export LC_ALL=C

ORIGINAL_ARGS=("$@")
CALLER_USER="${SUDO_USER:-$(id -un)}"
CALLER_HOME="$(getent passwd "${CALLER_USER}" 2>/dev/null | awk -F: 'NR == 1 {print $6}')"
[[ -n "${CALLER_HOME}" ]] || CALLER_HOME="${HOME}"
CALLER_UID="$(id -u "${CALLER_USER}")"
CALLER_GID="$(id -g "${CALLER_USER}")"
STATE_ROOT="${SOLAB_TOOLS_STATE_DIR:-${CALLER_HOME}/.local/state/solab-tools}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE_ROOT="$(readlink -m -- "${STATE_ROOT}")"
case "${STATE_ROOT}" in
  "${REPOSITORY_ROOT}"|"${REPOSITORY_ROOT}"/*)
    echo "ERROR: run logs must stay outside the solab-tools checkout: ${STATE_ROOT}" >&2
    exit 1
    ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export STAMP
LOGGING_STARTED=0
OUT_DIR=""
RESULT_STATE="UNKNOWN"
RESULT_MESSAGE=""
RESULT_DEVICE=""
RESULT_MOUNTPOINT=""

usage() {
  cat <<'EOF'
Usage:
  inspect_mount_and_persist_existing_disk.sh detect [--rescan]
  inspect_mount_and_persist_existing_disk.sh check_data --dev DEV|--serial SERIAL|--uuid UUID [--sample-mib N]
  inspect_mount_and_persist_existing_disk.sh mount --dev DEV|--serial SERIAL|--uuid UUID --mountpoint DIR [--options OPTS] [--read-only] [--allow-nonempty]
  inspect_mount_and_persist_existing_disk.sh fstab --dev DEV|--serial SERIAL|--uuid UUID --mountpoint DIR [--options OPTS] [--apply] [--mount-now]

Commands:
  detect      List detected disks, NVMe/PCIe information, stable by-id/by-path
              links, and current mounts. --rescan requests administrator access
              and triggers SCSI and PCI rescans.

  check_data  Inspect a disk or partition without writing to it:
              - blkid/wipefs/partition table signature
              - If a filesystem is present, mount it temporarily as read-only
                and list a small sample of entries.
              - If no signature is recognized, sample several locations near
                the beginning, middle, and end and count nonzero bytes.
              Sampling is not a full-device zero scan. It only reports what was
              observed at the sampled locations.

  mount       Mount an existing filesystem without formatting or wiping it.
              For a whole disk with exactly one filesystem-bearing partition,
              that partition is selected automatically. If several filesystems
              are found, specify the exact partition with --dev.

  fstab       Generate or install a UUID-based /etc/fstab entry. The default is
              a dry run. --apply is required to modify /etc/fstab. The script
              creates a backup and validates the candidate with findmnt --verify.

Examples:
  inspect_mount_and_persist_existing_disk.sh detect
  inspect_mount_and_persist_existing_disk.sh detect --rescan
  inspect_mount_and_persist_existing_disk.sh check_data --serial DISK_SERIAL
  inspect_mount_and_persist_existing_disk.sh mount --serial DISK_SERIAL --mountpoint /mnt/data
  inspect_mount_and_persist_existing_disk.sh fstab --serial DISK_SERIAL --mountpoint /mnt/data --apply --mount-now

Environment variables:
  DISK_TOOL_NO_LOG=1
                   Disable run logs.
  SOLAB_TOOLS_STATE_DIR=DIR
                   Write logs under DIR. The default is
                   ~/.local/state/solab-tools.
EOF
}

die() {
  echo "ERROR: $*" >&2
  RESULT_STATE="ERROR"
  RESULT_MESSAGE="$*"
  exit 1
}

section() {
  printf '\n===== %s =====\n' "$*"
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

warn_run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@" || true
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo is required but is not installed or available in PATH"
  local script_path
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- env \
    DISK_TOOL_NO_LOG="${DISK_TOOL_NO_LOG:-0}" \
    SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${script_path}" "${ORIGINAL_ARGS[@]}"
}

start_log() {
  local task="$1"
  local default_state_root="${CALLER_HOME}/.local/state/solab-tools"
  local directory
  if [[ "${DISK_TOOL_NO_LOG:-0}" == "1" ]]; then
    return 0
  fi

  OUT_DIR="${STATE_ROOT}/${STAMP}-${task}"
  if [[ "${EUID}" -eq 0 && "${CALLER_USER}" != root && "${STATE_ROOT}" == "${default_state_root}" ]]; then
    for directory in "${CALLER_HOME}/.local" "${CALLER_HOME}/.local/state" "${default_state_root}"; do
      [[ ! -L "${directory}" ]] || die "refusing to repair symlinked state directory: ${directory}"
      mkdir -p "${directory}"
      chown "${CALLER_UID}:${CALLER_GID}" "${directory}"
      chmod u+rwx "${directory}"
    done
    chown -R "${CALLER_UID}:${CALLER_GID}" "${default_state_root}"
  elif ! mkdir -p "${STATE_ROOT}" 2>/dev/null; then
    if [[ "${EUID}" -ne 0 ]]; then
      echo 'State log permissions require repair; requesting sudo authentication...'
      require_root
    fi
    die "could not create state directory: ${STATE_ROOT}"
  fi

  if [[ "${EUID}" -eq 0 && "${CALLER_USER}" != root ]]; then
    install -d -o "${CALLER_UID}" -g "${CALLER_GID}" -m 0700 "${OUT_DIR}"
  else
    mkdir -p "${OUT_DIR}"
  fi
  LOGGING_STARTED=1
  exec > >(tee -a "${OUT_DIR}/output.log") 2>&1
}

finish_log() {
  local rc=$?
  if [[ "${LOGGING_STARTED}" == "1" ]]; then
    {
      echo "time=${STAMP}"
      echo "host=$(hostname 2>/dev/null || true)"
      echo "command=${1:-unknown}"
      echo "exit_code=${rc}"
      echo "state=${RESULT_STATE}"
      echo "message=${RESULT_MESSAGE}"
      echo "device=${RESULT_DEVICE}"
      echo "mountpoint=${RESULT_MOUNTPOINT}"
      echo "result_dir=${OUT_DIR}"
    } >"${OUT_DIR}/summary.txt"

    if [[ "${EUID}" -eq 0 && "${CALLER_USER}" != root ]]; then
      chown -R "${CALLER_UID}:${CALLER_GID}" "${OUT_DIR}" || true
    fi
    echo
    echo "Log directory: ${OUT_DIR}"
  fi
  exit "${rc}"
}

block_type() {
  lsblk -dnro TYPE "$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

resolve_device() {
  local dev_arg="$1"
  local serial_arg="$2"
  local uuid_arg="$3"
  local found

  if [[ -n "${dev_arg}" ]]; then
    found="$(readlink -f "${dev_arg}")"
    [[ -b "${found}" ]] || die "not a block device: ${dev_arg}"
    printf '%s\n' "${found}"
    return 0
  fi

  if [[ -n "${uuid_arg}" ]]; then
    found="$(blkid -U "${uuid_arg}" 2>/dev/null || true)"
    [[ -n "${found}" && -b "${found}" ]] || die "no block device found for UUID=${uuid_arg}"
    printf '%s\n' "${found}"
    return 0
  fi

  if [[ -n "${serial_arg}" ]]; then
    mapfile -t matches < <(
      lsblk -dnpo NAME,TYPE,SERIAL 2>/dev/null \
        | awk -v serial="${serial_arg}" '$2 == "disk" && $3 == serial {print $1}'
    )
    if [[ "${#matches[@]}" -eq 0 ]]; then
      die "no whole-disk device found with serial=${serial_arg}; run inspect_mount_and_persist_existing_disk.sh detect to list serial numbers"
    fi
    if [[ "${#matches[@]}" -gt 1 ]]; then
      printf 'serial=%s matches multiple devices:\n' "${serial_arg}" >&2
      printf '  %s\n' "${matches[@]}" >&2
      die "use --dev to select one device explicitly"
    fi
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  die "specify one of --dev DEV, --serial SERIAL, or --uuid UUID"
}

stable_links_for() {
  local node="$1"
  local resolved
  resolved="$(readlink -f "${node}")"
  for dir in /dev/disk/by-id /dev/disk/by-path; do
    [[ -d "${dir}" ]] || continue
    find "${dir}" -maxdepth 1 -type l -printf '%p\n' 2>/dev/null \
      | while read -r link; do
          if [[ "$(readlink -f "${link}")" == "${resolved}" ]]; then
            printf '%s\n' "${link}"
          fi
        done
  done | sort
}

print_device_identity() {
  local dev="$1"
  section "device identity: ${dev}"
  warn_run lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,TRAN,ROTA,RM,STATE,FSTYPE,LABEL,UUID,MOUNTPOINTS "${dev}"
  echo
  echo "Stable paths:"
  stable_links_for "${dev}" | sed 's/^/  /' || true
  echo
  warn_run blkid "${dev}"
  warn_run wipefs -n "${dev}"
}

pci_slot_for_bdf() {
  local bdf="$1"
  local slot=""
  [[ -n "${bdf}" ]] || return 0
  if command -v lspci >/dev/null 2>&1; then
    slot="$(lspci -Dvv -s "${bdf}" 2>/dev/null | awk -F: '/Physical Slot/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
  fi
  printf '%s\n' "${slot}"
}

pci_link_for_bdf() {
  local bdf="$1"
  local link=""
  [[ -n "${bdf}" ]] || return 0
  if command -v lspci >/dev/null 2>&1; then
    link="$(lspci -Dvv -s "${bdf}" 2>/dev/null | awk '/LnkSta:/ {sub(/^[ \t]+/, ""); print; exit}')"
  fi
  printf '%s\n' "${link}"
}

nvme_pci_mapping() {
  section "NVMe / PCIe mapping"
  printf '%-14s %-18s %-22s %-14s %-10s %s\n' "DEV" "MODEL" "SERIAL" "PCI_BDF" "SLOT" "LINK"
  for sysdev in /sys/block/nvme*n1; do
    [[ -e "${sysdev}" ]] || continue
    local base ctrl model serial bdf slot link
    base="$(basename "${sysdev}")"
    ctrl="${base%n1}"
    model="$(cat "${sysdev}/device/model" 2>/dev/null | tr -d '\n' || true)"
    serial="$(cat "${sysdev}/device/serial" 2>/dev/null | tr -d '\n' || true)"
    if [[ -e "/sys/class/nvme/${ctrl}/device" ]]; then
      bdf="$(basename "$(readlink -f "/sys/class/nvme/${ctrl}/device")")"
    else
      bdf=""
    fi
    slot="$(pci_slot_for_bdf "${bdf}")"
    link="$(pci_link_for_bdf "${bdf}")"
    printf '%-14s %-18s %-22s %-14s %-10s %s\n' "/dev/${base}" "${model}" "${serial}" "${bdf}" "${slot:-?}" "${link:-?}"
    stable_links_for "/dev/${base}" | sed 's/^/  /' || true
  done
}

candidate_status_for_disk() {
  local dev="$1"
  local mounts
  mounts="$(lsblk -nrpo MOUNTPOINTS "${dev}" 2>/dev/null | awk 'NF {print}' | paste -sd ',' -)"
  if [[ -n "${mounts}" ]]; then
    printf 'MOUNTED(%s)' "${mounts}"
  elif lsblk -nrpo TYPE,FSTYPE "${dev}" 2>/dev/null | awk '$1 != "disk" && $2 != "" {found=1} END {exit found ? 0 : 1}'; then
    printf 'HAS_FS_UNMOUNTED'
  elif blkid -p "${dev}" >/dev/null 2>&1; then
    printf 'HAS_SIGNATURE'
  else
    printf 'NO_MOUNT_SEEN'
  fi
}

cmd_detect() {
  local do_rescan=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --rescan) do_rescan=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown detect option: $1" ;;
    esac
  done

  if [[ "${do_rescan}" -eq 1 ]]; then
    require_root
  fi

  start_log "existing-disk-detect"
  trap 'finish_log detect' EXIT
  RESULT_STATE="RUNNING"

  section "system information"
  warn_run hostname
  warn_run date -Is
  warn_run uname -a
  echo "state_root=${STATE_ROOT}"

  if [[ "${do_rescan}" -eq 1 ]]; then
    section "rescan"
    for scan in /sys/class/scsi_host/host*/scan; do
      [[ -w "${scan}" ]] || continue
      echo "- - -" >"${scan}" || true
      echo "scanned ${scan}"
    done
    if [[ -w /sys/bus/pci/rescan ]]; then
      echo 1 >/sys/bus/pci/rescan || true
      echo "scanned /sys/bus/pci/rescan"
    else
      echo "/sys/bus/pci/rescan is not writable"
    fi
    warn_run udevadm settle --timeout=20
    sleep 2
  fi

  section "lsblk"
  warn_run lsblk -e7 -o NAME,PATH,MAJ:MIN,TYPE,SIZE,MODEL,SERIAL,WWN,TRAN,ROTA,RM,STATE,FSTYPE,LABEL,UUID,MOUNTPOINTS

  section "whole-disk candidate overview"
  printf '%-18s %-10s %-10s %-22s %-24s %s\n' "DEV" "SIZE" "TRAN" "SERIAL" "STATUS" "MODEL"
  while IFS= read -r line; do
    local NAME="" SIZE="" TRAN="" SERIAL="" MODEL=""
    eval "${line}"
    [[ -n "${NAME}" ]] || continue
    printf '%-18s %-10s %-10s %-22s %-24s %s\n' "${NAME}" "${SIZE}" "${TRAN:-?}" "${SERIAL:-?}" "$(candidate_status_for_disk "${NAME}")" "${MODEL}"
  done < <(lsblk -dnP -p -o NAME,SIZE,TRAN,SERIAL,MODEL)

  section "stable by-id/by-path links"
  warn_run find /dev/disk/by-id /dev/disk/by-path -maxdepth 1 -type l -printf '%p -> %l\n'

  if command -v nvme >/dev/null 2>&1; then
    section "nvme list"
    warn_run nvme list
    warn_run nvme list-subsys
  else
    echo "nvme command not found; skipping nvme list"
  fi

  if command -v lspci >/dev/null 2>&1; then
    section "PCIe storage devices"
    lspci -Dnn | grep -Ei 'non-volatile|nvme|storage|raid|sata|sas|ahci' || true
  fi
  nvme_pci_mapping

  section "current mounts and fstab"
  warn_run findmnt -R /mnt /shared
  echo
  warn_run grep -nE '^[[:space:]]*[^#].*([[:space:]]/mnt/|[[:space:]]/shared/)' /etc/fstab

  if [[ "${EUID}" -eq 0 ]]; then
    section "recent storage-related dmesg"
    dmesg -T | grep -Ei 'nvme|pcie|pci |aer|dpc|reset|timeout|link down|link up|failed|error|I/O|blk|ata|ahci|scsi|disk' | tail -200 || true
  else
    echo
    echo "Tip: detect --rescan requests administrator access automatically and includes dmesg evidence."
  fi

  RESULT_STATE="PASS"
  RESULT_MESSAGE="detection completed"
}

choose_mount_source() {
  local dev="$1"
  local fstype type
  type="$(block_type "${dev}")"
  fstype="$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)"
  if [[ -n "${fstype}" ]]; then
    printf '%s\n' "${dev}"
    return 0
  fi

  if [[ "${type}" != "disk" ]]; then
    die "${dev} has no recognized filesystem and cannot be mounted"
  fi

  mapfile -t fs_children < <(lsblk -nrpo NAME,TYPE,FSTYPE "${dev}" | awk '$2 != "disk" && $3 != "" {print $1}')
  if [[ "${#fs_children[@]}" -eq 1 ]]; then
    printf '%s\n' "${fs_children[0]}"
    return 0
  fi
  if [[ "${#fs_children[@]}" -eq 0 ]]; then
    die "${dev} has no filesystem-bearing partition; this script never formats devices automatically"
  fi

  printf '%s has multiple filesystem-bearing child devices; select one explicitly with --dev:\n' "${dev}" >&2
  printf '  %s\n' "${fs_children[@]}" >&2
  die "multiple filesystems found; refusing to guess"
}

list_filesystem_readonly() {
  local node="$1"
  local tmp err mounted target
  target="$(findmnt -rn -S "${node}" -o TARGET | head -n 1 || true)"
  if [[ -n "${target}" ]]; then
    echo "Already mounted at ${target}; listing up to 80 entries:"
    find "${target}" -xdev -mindepth 1 -maxdepth 2 -printf '%M %u:%g %s %p\n' 2>/dev/null | head -80 || true
    return 0
  fi

  tmp="$(mktemp -d)"
  err="$(mktemp)"
  mounted=0
  if mount -o ro,noload "${node}" "${tmp}" 2>"${err}"; then
    mounted=1
  elif mount -o ro "${node}" "${tmp}" 2>>"${err}"; then
    mounted=1
  fi

  if [[ "${mounted}" -eq 1 ]]; then
    echo "Temporarily mounted ${node} read-only at ${tmp}; listing up to 80 entries:"
    find "${tmp}" -xdev -mindepth 1 -maxdepth 2 -printf '%M %u:%g %s %p\n' 2>/dev/null | sed "s# ${tmp}/# /#" | head -80 || true
    umount "${tmp}" || true
  else
    echo "Could not mount ${node} read-only:"
    cat "${err}" || true
  fi
  rm -rf "${tmp}" "${err}"
}

raw_sample_device() {
  local dev="$1"
  local out_report="$2"
  local sample_mib="$3"
  local size_bytes sample_len alignment offset max_offset read_len
  local sample_file bytes_read nonzero head32 total_nonzero total_read sample_count
  local -a raw_offsets
  local -A seen_offsets=()
  size_bytes="$(blockdev --getsize64 "${dev}")"
  [[ "${size_bytes}" =~ ^[0-9]+$ ]] && (( size_bytes > 0 )) || \
    die "could not determine a positive byte size for ${dev}"
  [[ "${sample_mib}" =~ ^[0-9]+$ ]] && (( sample_mib > 0 )) || \
    die "--sample-mib must be a positive integer"

  sample_len="$((sample_mib * 1024 * 1024))"
  (( sample_len < 4096 )) && sample_len=4096
  (( sample_len > size_bytes )) && sample_len="${size_bytes}"
  alignment=4096
  max_offset="$((size_bytes - sample_len))"
  raw_offsets=(
    0
    4096
    $((1024 * 1024))
    $((16 * 1024 * 1024))
    $((128 * 1024 * 1024))
    $((size_bytes / 4))
    $((size_bytes / 2))
    $((size_bytes * 3 / 4))
    $((size_bytes > 128 * 1024 * 1024 ? size_bytes - 128 * 1024 * 1024 : 0))
    $((size_bytes > 16 * 1024 * 1024 ? size_bytes - 16 * 1024 * 1024 : 0))
    $((size_bytes > 1024 * 1024 ? size_bytes - 1024 * 1024 : 0))
  )

  printf 'offset_bytes\tbytes_read\tnonzero_bytes\thead32_hex\n' >"${out_report}"
  total_nonzero=0
  total_read=0
  sample_count=0
  for offset in "${raw_offsets[@]}"; do
    (( offset > max_offset )) && offset="${max_offset}"
    offset="$((offset / alignment * alignment))"
    [[ -z "${seen_offsets[${offset}]:-}" ]] || continue
    seen_offsets[${offset}]=1
    read_len="${sample_len}"
    (( offset + read_len > size_bytes )) && read_len="$((size_bytes - offset))"
    sample_file="$(mktemp)"
    if ! dd if="${dev}" of="${sample_file}" iflag=skip_bytes,count_bytes \
      skip="${offset}" count="${read_len}" status=none; then
      rm -f -- "${sample_file}"
      die "raw read failed at offset ${offset} on ${dev}"
    fi
    bytes_read="$(wc -c <"${sample_file}")"
    nonzero="$(tr -d '\000' <"${sample_file}" | wc -c)"
    head32="$(od -An -v -tx1 -N32 "${sample_file}" | tr -d ' \n')"
    rm -f -- "${sample_file}"
    printf '%s\t%s\t%s\t%s\n' \
      "${offset}" "${bytes_read}" "${nonzero}" "${head32}" | tee -a "${out_report}"
    total_nonzero="$((total_nonzero + nonzero))"
    total_read="$((total_read + bytes_read))"
    sample_count="$((sample_count + 1))"
  done

  RAW_SAMPLE_NONZERO_BYTES="${total_nonzero}"
  echo "RAW_SAMPLE_DEVICE=${dev}"
  echo "RAW_SAMPLE_SIZE_BYTES=${size_bytes}"
  echo "RAW_SAMPLE_COUNT=${sample_count}"
  echo "RAW_SAMPLE_TOTAL_BYTES_READ=${total_read}"
  echo "RAW_SAMPLE_NONZERO_BYTES=${RAW_SAMPLE_NONZERO_BYTES}"
  echo "RAW_SAMPLE_REPORT=${out_report}"
}

cmd_check_data() {
  local dev_arg="" serial_arg="" uuid_arg="" sample_mib=1 dev raw_report nonzero
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dev) dev_arg="${2:-}"; shift 2 ;;
      --serial) serial_arg="${2:-}"; shift 2 ;;
      --uuid) uuid_arg="${2:-}"; shift 2 ;;
      --sample-mib) sample_mib="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown check_data option: $1" ;;
    esac
  done

  require_root
  require_cmd blockdev
  require_cmd blkid
  require_cmd lsblk
  require_cmd mount
  require_cmd wipefs
  require_cmd dd
  require_cmd od
  require_cmd tr
  require_cmd wc

  start_log "existing-disk-check-data"
  trap 'finish_log check_data' EXIT
  RESULT_STATE="RUNNING"

  dev="$(resolve_device "${dev_arg}" "${serial_arg}" "${uuid_arg}")"
  RESULT_DEVICE="${dev}"
  print_device_identity "${dev}"

  section "partition and signature checks"
  warn_run parted -s "${dev}" print
  mapfile -t nodes < <(lsblk -nrpo NAME,TYPE "${dev}" | awk '$2 == "disk" || $2 == "part" {print $1}')

  local signature_found=0
  local fs_found=0
  local node fstype wipe_out blkid_out
  for node in "${nodes[@]}"; do
    echo
    echo "--- ${node} ---"
    fstype="$(blkid -s TYPE -o value "${node}" 2>/dev/null || true)"
    if [[ -n "${fstype}" ]]; then
      fs_found=1
      signature_found=1
      echo "Filesystem: ${fstype}"
      warn_run blkid "${node}"
      list_filesystem_readonly "${node}"
      continue
    fi

    if blkid_out="$(blkid -p "${node}" 2>&1)"; then
      signature_found=1
      echo "blkid found a signature:"
      echo "${blkid_out}"
    else
      echo "blkid found no filesystem signature"
    fi

    wipe_out="$(wipefs -n "${node}" 2>&1 || true)"
    echo "wipefs -n output:"
    echo "${wipe_out:-<empty>}"
    if printf '%s\n' "${wipe_out}" | awk 'NR > 1 && NF {found=1} END {exit found ? 0 : 1}'; then
      signature_found=1
    fi
  done

  if [[ "${fs_found}" -eq 1 ]]; then
    RESULT_STATE="DATA_FOUND"
    RESULT_MESSAGE="recognized filesystem found; a read-only content sample is shown above"
    echo
    echo "Conclusion: a filesystem was found, so treat the device as containing data or at least a mountable structure."
    return 0
  fi

  if [[ "${signature_found}" -eq 1 ]]; then
    RESULT_STATE="SIGNATURE_FOUND"
    RESULT_MESSAGE="partition or signature found; do not treat the device as empty"
    echo
    echo "Conclusion: a partition table or another signature was found; do not treat the device as empty."
    return 0
  fi

  section "raw device sampling"
  raw_report="${OUT_DIR:-/tmp}/$(basename "${dev}")-raw-sample.tsv"
  RAW_SAMPLE_NONZERO_BYTES=0
  raw_sample_device "${dev}" "${raw_report}" "${sample_mib}"
  nonzero="${RAW_SAMPLE_NONZERO_BYTES}"
  if [[ "${nonzero}" != "0" ]]; then
    RESULT_STATE="SAMPLE_NONZERO_FOUND"
    RESULT_MESSAGE="nonzero bytes found in samples; the device may contain data and must not be treated as empty"
    echo
    echo "Conclusion: samples contained ${nonzero} nonzero bytes, so the device may contain data."
  else
    RESULT_STATE="NO_OBVIOUS_DATA_IN_SAMPLES"
    RESULT_MESSAGE="no signature or nonzero sampled byte found; this does not prove the entire device is zero-filled"
    echo
    echo "Conclusion: no signature or nonzero sampled byte was found. This is not proof that the entire device is zero-filled."
  fi
}

cmd_mount() {
  local dev_arg="" serial_arg="" uuid_arg="" mountpoint="" options="defaults" read_only=0 allow_nonempty=0
  local dev source fstype
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dev) dev_arg="${2:-}"; shift 2 ;;
      --serial) serial_arg="${2:-}"; shift 2 ;;
      --uuid) uuid_arg="${2:-}"; shift 2 ;;
      --mountpoint) mountpoint="${2:-}"; shift 2 ;;
      --options) options="${2:-}"; shift 2 ;;
      --read-only|--ro) read_only=1; shift ;;
      --allow-nonempty) allow_nonempty=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown mount option: $1" ;;
    esac
  done

  require_root
  [[ -n "${mountpoint}" ]] || die "mount requires --mountpoint DIR"
  require_cmd blkid
  require_cmd findmnt
  require_cmd mount

  start_log "existing-disk-mount"
  trap 'finish_log mount' EXIT
  RESULT_STATE="RUNNING"

  dev="$(resolve_device "${dev_arg}" "${serial_arg}" "${uuid_arg}")"
  source="$(choose_mount_source "${dev}")"
  RESULT_DEVICE="${source}"
  RESULT_MOUNTPOINT="${mountpoint}"
  fstype="$(blkid -s TYPE -o value "${source}" 2>/dev/null || true)"
  [[ -n "${fstype}" ]] || die "${source} has no recognized filesystem"

  print_device_identity "${source}"
  section "pre-mount checks"
  if findmnt --mountpoint "${mountpoint}" >/dev/null 2>&1; then
    current_source="$(findmnt --mountpoint "${mountpoint}" -no SOURCE)"
    if [[ "$(readlink -f "${current_source}" 2>/dev/null || echo "${current_source}")" == "$(readlink -f "${source}")" ]]; then
      RESULT_STATE="PASS"
      RESULT_MESSAGE="${source} is already mounted at ${mountpoint}"
      echo "${source} is already mounted at ${mountpoint}"
      return 0
    fi
    die "${mountpoint} is already a mountpoint for another source: ${current_source}"
  fi

  mkdir -p "${mountpoint}"
  if [[ "${allow_nonempty}" -ne 1 ]] && find "${mountpoint}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "${mountpoint} is not empty; use --allow-nonempty only if hiding its current contents is intentional"
  fi

  if [[ "${read_only}" -eq 1 ]]; then
    if [[ "${options}" == "defaults" ]]; then
      options="ro"
    else
      options="${options},ro"
    fi
  fi

  section "mount filesystem"
  run mount -o "${options}" "${source}" "${mountpoint}"
  warn_run findmnt --mountpoint "${mountpoint}" -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID
  warn_run df -h "${mountpoint}"

  RESULT_STATE="PASS"
  RESULT_MESSAGE="mounted ${source} at ${mountpoint}"
}

cmd_fstab() {
  local dev_arg="" serial_arg="" uuid_arg="" mountpoint="" options="defaults,nofail" apply=0 mount_now=0 passno=""
  local dev source fstype uuid entry tmp backup
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dev) dev_arg="${2:-}"; shift 2 ;;
      --serial) serial_arg="${2:-}"; shift 2 ;;
      --uuid) uuid_arg="${2:-}"; shift 2 ;;
      --mountpoint) mountpoint="${2:-}"; shift 2 ;;
      --options) options="${2:-}"; shift 2 ;;
      --passno) passno="${2:-}"; shift 2 ;;
      --apply) apply=1; shift ;;
      --mount-now) mount_now=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown fstab option: $1" ;;
    esac
  done

  require_root
  [[ -n "${mountpoint}" ]] || die "fstab requires --mountpoint DIR"
  require_cmd blkid
  require_cmd findmnt
  require_cmd install
  require_cmd mount

  start_log "existing-disk-fstab"
  trap 'finish_log fstab' EXIT
  RESULT_STATE="RUNNING"

  dev="$(resolve_device "${dev_arg}" "${serial_arg}" "${uuid_arg}")"
  source="$(choose_mount_source "${dev}")"
  RESULT_DEVICE="${source}"
  RESULT_MOUNTPOINT="${mountpoint}"
  fstype="$(blkid -s TYPE -o value "${source}" 2>/dev/null || true)"
  uuid="$(blkid -s UUID -o value "${source}" 2>/dev/null || true)"
  [[ -n "${fstype}" ]] || die "${source} has no recognized filesystem"
  [[ -n "${uuid}" ]] || die "${source} has no UUID, so a safe fstab entry cannot be written"
  if [[ -z "${passno}" ]]; then
    case "${fstype}" in
      ext2|ext3|ext4) passno=2 ;;
      *) passno=0 ;;
    esac
  fi

  entry="UUID=${uuid} ${mountpoint} ${fstype} ${options} 0 ${passno}"

  section "proposed fstab entry"
  print_device_identity "${source}"
  echo "${entry}"
  echo
  echo "An existing entry with the same mountpoint or UUID will be removed before the line above is appended."

  tmp="$(mktemp)"
  awk -v target="${mountpoint}" -v uuid="UUID=${uuid}" '
    $0 ~ /^[[:space:]]*#/ { print; next }
    NF >= 2 && ($2 == target || $1 == uuid) { next }
    { print }
  ' /etc/fstab >"${tmp}"
  printf '%s\n' "${entry}" >>"${tmp}"

  section "validate candidate fstab"
  if [[ ! -d "${mountpoint}" ]]; then
    if [[ "${apply}" -eq 1 ]]; then
      run mkdir -p "${mountpoint}"
    else
      echo "DRY-RUN: ${mountpoint} does not exist and will not be created; any findmnt missing-mountpoint warning is informational."
    fi
  fi
  if [[ "${apply}" -eq 1 ]]; then
    run findmnt --verify --verbose --tab-file "${tmp}"
  else
    warn_run findmnt --verify --verbose --tab-file "${tmp}"
  fi

  if [[ "${apply}" -ne 1 ]]; then
    RESULT_STATE="DRY_RUN"
    RESULT_MESSAGE="dry run completed; --apply is required to write /etc/fstab"
    echo
    echo "DRY-RUN: /etc/fstab was not modified. After review, run the same command with --apply."
    rm -f "${tmp}"
    return 0
  fi

  section "install /etc/fstab"
  backup="/etc/fstab.bak.${STAMP}"
  run cp -a /etc/fstab "${backup}"
  run install -m 0644 "${tmp}" /etc/fstab
  rm -f "${tmp}"
  if command -v systemctl >/dev/null 2>&1; then
    warn_run systemctl daemon-reload
  fi
  run findmnt --verify --verbose --tab-file /etc/fstab

  if [[ "${mount_now}" -eq 1 ]]; then
    section "mount from fstab now"
    if findmnt --mountpoint "${mountpoint}" >/dev/null 2>&1; then
      warn_run findmnt --mountpoint "${mountpoint}" -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID
    else
      run mount "${mountpoint}"
      warn_run findmnt --mountpoint "${mountpoint}" -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID
    fi
  fi

  RESULT_STATE="PASS"
  RESULT_MESSAGE="updated /etc/fstab; backup: ${backup}"
  echo "fstab_backup=${backup}"
}

main() {
  local cmd="${1:-help}"
  if [[ "$#" -gt 0 ]]; then
    shift
  fi
  case "${cmd}" in
    help|-h|--help) usage ;;
    detect) cmd_detect "$@" ;;
    check_data) cmd_check_data "$@" ;;
    mount) cmd_mount "$@" ;;
    fstab) cmd_fstab "$@" ;;
    *) usage >&2; die "unknown subcommand: ${cmd}" ;;
  esac
}

main "$@"
