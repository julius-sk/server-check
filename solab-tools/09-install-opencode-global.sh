#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Install the latest official OpenCode CLI binary from GitHub Releases for all users.
set -Eeuo pipefail

TOOL_NAME="${BASH_SOURCE[0]##*/}"
original_args=("$@")
GITHUB_REPOSITORY="anomalyco/opencode"
RELEASE_TAG="${RELEASE_TAG:-latest}"
LINK_DIR="${LINK_DIR:-/usr/local/bin}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"
USE_BASELINE="${USE_BASELINE:-auto}"
LIBC_VARIANT="${LIBC_VARIANT:-auto}"
WORKDIR=""

log() {
  printf '[%s] INFO: %s\n' "$TOOL_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$TOOL_NAME" "$*" >&2
  exit 1
}

ok() {
  printf '[%s] OK: %s\n' "$TOOL_NAME" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'USAGE'
Install the latest official OpenCode CLI binary from GitHub Releases for all users.

Usage:
  bash 09-install-opencode-global.sh

The default latest release follows GitHub's latest stable release redirect.
The installer automatically selects Linux x64, x64 baseline, ARM64, glibc,
or musl assets. It downloads without npm or Node.js and requests sudo only
when installing the binary under /usr/local/bin.

Environment:
  RELEASE_TAG       GitHub tag such as v1.18.3, or latest. Default: latest.
  LINK_DIR          Global binary directory. Default: /usr/local/bin.
  USE_BASELINE      auto, yes, or no for x64 CPUs. Default: auto.
  LIBC_VARIANT      auto, glibc, or musl. Default: auto.
  TIMEOUT_SECONDS   Download timeout. Default: 1200 seconds.
USAGE
}

cleanup() {
  local rc=$?
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" \
      && -f "$WORKDIR/.solab-github-release-installer" ]]; then
    rm -rf -- "$WORKDIR" || true
  fi
  return "$rc"
}

fetch_to_file() {
  local url="$1"
  local out="$2"
  if have curl; then
    curl -fL --retry 3 --connect-timeout 20 --max-time "$TIMEOUT_SECONDS" \
      --progress-bar -o "$out" "$url"
  elif have wget; then
    timeout "$TIMEOUT_SECONDS" \
      wget --timeout=30 --tries=3 -O "$out" "$url"
  else
    die "curl or wget is required to download $url"
  fi
}

resolve_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "unsupported Linux architecture: $(uname -m)" ;;
  esac
}

resolve_baseline_suffix() {
  local arch="$1"
  case "$USE_BASELINE" in
    auto)
      if [[ "$arch" == x64 ]] \
          && ! grep -Eiq '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
        printf '%s\n' '-baseline'
      else
        printf '\n'
      fi
      ;;
    yes|true|1)
      [[ "$arch" == x64 ]] || die "baseline assets are only available for x64"
      printf '%s\n' '-baseline'
      ;;
    no|false|0) printf '\n' ;;
    *) die "USE_BASELINE must be auto, yes, or no" ;;
  esac
}

resolve_libc_suffix() {
  case "$LIBC_VARIANT" in
    auto)
      if [[ -f /etc/alpine-release ]] \
          || { have ldd && ldd --version 2>&1 | grep -qi musl; }; then
        printf '%s\n' '-musl'
      else
        printf '\n'
      fi
      ;;
    glibc) printf '\n' ;;
    musl) printf '%s\n' '-musl' ;;
    *) die "LIBC_VARIANT must be auto, glibc, or musl" ;;
  esac
}

release_download_url() {
  local asset="$1"
  if [[ "$RELEASE_TAG" == latest ]]; then
    printf 'https://github.com/%s/releases/latest/download/%s\n' \
      "$GITHUB_REPOSITORY" "$asset"
  else
    printf 'https://github.com/%s/releases/download/%s/%s\n' \
      "$GITHUB_REPOSITORY" "$RELEASE_TAG" "$asset"
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac
[[ "$#" -le 1 ]] || die "too many arguments"
[[ "$RELEASE_TAG" == latest || "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "RELEASE_TAG must be latest or an exact tag such as v1.18.3"

[[ "$(uname -s)" == Linux ]] || die "this installer only supports Linux"
if [[ "$(id -u)" -ne 0 ]]; then
  have sudo || die "sudo is required but is not installed or available in PATH"
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  sudo_env=(
    "RELEASE_TAG=$RELEASE_TAG"
    "LINK_DIR=$LINK_DIR"
    "TIMEOUT_SECONDS=$TIMEOUT_SECONDS"
    "USE_BASELINE=$USE_BASELINE"
    "LIBC_VARIANT=$LIBC_VARIANT"
  )
  [[ -z "${SSL_CERT_FILE:-}" ]] || sudo_env+=("SSL_CERT_FILE=$SSL_CERT_FILE")
  [[ -z "${CURL_CA_BUNDLE:-}" ]] || sudo_env+=("CURL_CA_BUNDLE=$CURL_CA_BUNDLE")
  log "Administrator access is required; enter your password if prompted."
  exec sudo -- env "${sudo_env[@]}" bash "$script_path" "${original_args[@]}"
fi
have tar || die "tar is required"
have timeout || die "timeout is required"

arch="$(resolve_architecture)"
baseline_suffix="$(resolve_baseline_suffix "$arch")"
libc_suffix="$(resolve_libc_suffix)"
asset="opencode-linux-${arch}${baseline_suffix}${libc_suffix}.tar.gz"
download_url="$(release_download_url "$asset")"

WORKDIR="$(mktemp -d)"
: >"$WORKDIR/.solab-github-release-installer"
trap cleanup EXIT
archive="$WORKDIR/$asset"
extract_dir="$WORKDIR/extracted"
mkdir -p "$extract_dir"

log "host=$(hostname -f 2>/dev/null || hostname)"
log "release=$RELEASE_TAG asset=$asset"
log "downloading $download_url"
fetch_to_file "$download_url" "$archive"
tar -tzf "$archive" >/dev/null || die "downloaded file is not a valid gzip tar archive"
tar --no-same-owner -xzf "$archive" -C "$extract_dir"

mapfile -t binary_candidates < <(find "$extract_dir" -type f -name opencode -print)
[[ "${#binary_candidates[@]}" -eq 1 ]] \
  || die "expected one opencode binary in the release archive; found ${#binary_candidates[@]}"
binary="${binary_candidates[0]}"

install -d -m 0755 "$LINK_DIR"
if [[ -L "$LINK_DIR/opencode" ]]; then
  rm -f -- "$LINK_DIR/opencode"
fi
install -m 0755 "$binary" "$LINK_DIR/opencode"

[[ -x "$LINK_DIR/opencode" ]] || die "installed OpenCode binary is not executable"
log "installed_path=$LINK_DIR/opencode"
"$LINK_DIR/opencode" --version
ok "OpenCode is installed and verified."
