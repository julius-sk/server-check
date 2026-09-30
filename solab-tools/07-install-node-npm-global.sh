#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Install a checksum-verified system-wide Node.js and npm distribution.
set -Eeuo pipefail

TOOL_NAME="${BASH_SOURCE[0]##*/}"
original_args=("$@")
MODE="install"
NODE_VERSION="${NODE_VERSION:-v24.18.0}"
PREFIX="${PREFIX:-/usr/local/lib/nodejs}"
LINK_DIR="${LINK_DIR:-/usr/local/bin}"
DOWNLOAD_TIMEOUT_SECONDS="${DOWNLOAD_TIMEOUT_SECONDS:-1200}"
INSTALL_TMPDIR=""

usage() {
  cat <<'USAGE'
Install a system-wide Node.js + npm from the official Node.js Linux tarball.

This intentionally avoids `apt install nodejs npm`, which can fail when apt
tries to resolve a Node.js package against an older distro libuv1 package.

Usage:
  bash 07-install-node-npm-global.sh
  bash 07-install-node-npm-global.sh --diagnose

Options:
  --diagnose              Print host, apt, node, npm, and libuv state only.
  --node-version VALUE    lts, current, a major such as 22, or exact v22.16.0.
  --prefix DIR            Install versioned Node.js trees under DIR.
  --link-dir DIR          Symlink node/npm/npx/corepack into DIR.
  -h, --help              Show this help.

Environment:
  NODE_VERSION            Same as --node-version. Default: v24.18.0.
  PREFIX                  Default: /usr/local/lib/nodejs.
  LINK_DIR                Default: /usr/local/bin.
  DOWNLOAD_TIMEOUT_SECONDS  Per-download limit. Default: 1200 seconds.
  SSL_CERT_FILE           Optional custom CA bundle used by curl/OpenSSL.
  NODE_EXTRA_CA_CERTS     Optional extra CA file for later Node.js HTTPS use.
USAGE
}

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

next_step() {
  printf '[%s] NEXT: %s\n' "$TOOL_NAME" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

cleanup_install_tmpdir() {
  local rc=$?
  if [[ -n "${INSTALL_TMPDIR:-}" && -d "${INSTALL_TMPDIR}" \
      && -f "${INSTALL_TMPDIR}/.solab-node-installer-temp" ]]; then
    rm -rf -- "${INSTALL_TMPDIR}" || true
  fi
  return "${rc}"
}

fetch_to_file() {
  local url="$1"
  local out="$2"
  if have curl; then
    curl -fL --retry 3 --connect-timeout 20 \
      --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -o "$out" "$url"
  elif have wget; then
    timeout "$DOWNLOAD_TIMEOUT_SECONDS" \
      wget --timeout=30 --tries=3 -O "$out" "$url"
  else
    die "need curl or wget to download $url"
  fi
}

resolve_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) printf 'x64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l) printf 'armv7l\n' ;;
    *) die "unsupported architecture from uname -m: $machine" ;;
  esac
}

resolve_version() {
  local wanted="$1"
  local index_json="$2"

  if [[ "$wanted" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if [[ "$wanted" == v* ]]; then
      printf '%s\n' "$wanted"
    else
      printf 'v%s\n' "$wanted"
    fi
    return 0
  fi

  local selector version
  selector="${wanted,,}"
  case "$selector" in
    lts|latest-lts|stable)
      version="$(awk '/"lts"[[:space:]]*:[[:space:]]*"/ { if (match($0, /"version"[[:space:]]*:[[:space:]]*"v[0-9.]+"/)) { value=substr($0, RSTART, RLENGTH); sub(/^.*"v/, "v", value); sub(/"$/, "", value); print value; exit } }' "$index_json")"
      ;;
    current|latest)
      version="$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"(v[0-9.]+)".*/\1/p' "$index_json" | head -n1)"
      ;;
    v[0-9]*|[0-9]*)
      selector="${selector#v}"
      [[ "$selector" =~ ^[0-9]+$ ]] || die "invalid Node.js selector: $wanted"
      version="$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"(v'"$selector"'\.[0-9.]+)".*/\1/p' "$index_json" | head -n1)"
      ;;
    *) die "unsupported Node.js selector: $wanted" ;;
  esac
  [[ -n "$version" ]] || die "could not resolve Node.js version selector: $wanted"
  printf '%s\n' "$version"
}

diagnose() {
  echo "=== host ==="
  date -Is
  hostname -f 2>/dev/null || hostname
  id
  uname -a
  if [ -r /etc/os-release ]; then
    sed 's/^/os-release: /' /etc/os-release
  fi

  echo "=== existing node/npm ==="
  echo "PATH=$PATH"
  for cmd in node npm npx corepack; do
    if have "$cmd"; then
      printf '%s path=%s version=' "$cmd" "$(command -v "$cmd")"
      "$cmd" -v 2>&1 || true
    else
      printf '%s missing\n' "$cmd"
    fi
  done

  echo "=== dpkg packages ==="
  if have dpkg-query; then
    dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
      nodejs npm libuv1 libuv1t64 2>/dev/null || true
  else
    echo "dpkg-query missing"
  fi

  echo "=== apt policy ==="
  if have apt-cache; then
    apt-cache policy nodejs npm libuv1 libuv1t64 2>/dev/null || true
  else
    echo "apt-cache missing"
  fi

  echo "=== NodeSource apt entries ==="
  grep -RHs 'deb.nodesource.com' \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d/*.list \
    /etc/apt/sources.list.d/*.sources 2>/dev/null || true

  echo "=== suggested install command ==="
  if [ -f "$0" ]; then
    printf 'env NODE_VERSION=%q bash %q\n' "$NODE_VERSION" "$0"
  else
    printf 'env NODE_VERSION=%q bash /path/to/07-install-node-npm-global.sh\n' "$NODE_VERSION"
  fi
}

install_node() {
  if [ "$(id -u)" -ne 0 ]; then
    have sudo || die "sudo is required but is not installed or available in PATH"
    local script_path
    local -a sudo_env
    script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
    sudo_env=(
      "NODE_VERSION=${NODE_VERSION}"
      "PREFIX=${PREFIX}"
      "LINK_DIR=${LINK_DIR}"
      "DOWNLOAD_TIMEOUT_SECONDS=${DOWNLOAD_TIMEOUT_SECONDS}"
    )
    [[ -z "${SSL_CERT_FILE:-}" ]] || sudo_env+=("SSL_CERT_FILE=${SSL_CERT_FILE}")
    [[ -z "${NODE_EXTRA_CA_CERTS:-}" ]] || sudo_env+=("NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS}")
    log "Administrator access is required; enter your password if prompted."
    exec sudo -- env "${sudo_env[@]}" bash "${script_path}" "${original_args[@]}"
  fi
  [ "$(uname -s)" = "Linux" ] || die "this script only supports Linux"
  have tar || die "need tar"
  have sha256sum || die "sha256sum is required"
  have timeout || die "timeout is required"

  local arch index_json version archive_name archive sums target staging stamp
  arch="$(resolve_arch)"
  INSTALL_TMPDIR="$(mktemp -d)"
  : >"${INSTALL_TMPDIR}/.solab-node-installer-temp"
  trap cleanup_install_tmpdir EXIT

  index_json="$INSTALL_TMPDIR/index.json"
  if [[ "$NODE_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    version="$(resolve_version "$NODE_VERSION" "$index_json")"
  else
    fetch_to_file "https://nodejs.org/dist/index.json" "$index_json"
    version="$(resolve_version "$NODE_VERSION" "$index_json")"
  fi
  archive_name="node-${version}-linux-${arch}.tar.xz"
  archive="$INSTALL_TMPDIR/$archive_name"
  sums="$INSTALL_TMPDIR/SHASUMS256.txt"
  target="${PREFIX%/}/node-${version}-linux-${arch}"
  staging="${target}.staging.$$"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  log "installing $archive_name under ${PREFIX%/}"
  log "this tarball path avoids apt's nodejs/npm/libuv dependency resolver"
  fetch_to_file "https://nodejs.org/dist/${version}/${archive_name}" "$archive"

  fetch_to_file "https://nodejs.org/dist/${version}/SHASUMS256.txt" "$sums"
  grep "  ${archive_name}\$" "$sums" > "$INSTALL_TMPDIR/SHASUMS256.one" \
    || die "could not find $archive_name in SHASUMS256.txt"
  (cd "$INSTALL_TMPDIR" && sha256sum -c SHASUMS256.one)

  mkdir -p "${PREFIX%/}" "$LINK_DIR"
  rm -rf "$staging"
  mkdir -p "$staging"
  tar -xJf "$archive" -C "$staging" --strip-components=1
  if [ -e "$target" ] && [ ! -d "$target" ]; then
    die "target exists but is not a directory: $target"
  fi
  rm -rf "$target"
  mv "$staging" "$target"
  chown -R root:root "$target" 2>/dev/null || true
  chmod -R a+rX "$target"

  for bin in node npm npx corepack; do
    [ -x "$target/bin/$bin" ] || continue
    local dest="$LINK_DIR/$bin"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      local backup="${dest}.before-node-npm-${stamp}"
      log "backing up existing non-symlink $dest to $backup"
      mv "$dest" "$backup"
    fi
    ln -sfn "$target/bin/$bin" "$dest"
  done

  log "installed binaries:"
  "$LINK_DIR/node" -v
  "$LINK_DIR/npm" -v
  "$LINK_DIR/npx" -v
  if [ -x "$LINK_DIR/corepack" ]; then
    "$LINK_DIR/corepack" -v || true
  fi
  log "npm global prefix reported by this install:"
  "$LINK_DIR/npm" config get prefix || true
  ok "Node.js and npm are installed and verified."
  next_step "Ensure $LINK_DIR appears before /usr/bin in interactive PATH."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --diagnose) MODE="diagnose"; shift ;;
    --node-version) NODE_VERSION="${2:?missing value for --node-version}"; shift 2 ;;
    --prefix) PREFIX="${2:?missing value for --prefix}"; shift 2 ;;
    --link-dir) LINK_DIR="${2:?missing value for --link-dir}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$MODE" in
  diagnose) diagnose ;;
  install) install_node ;;
  *) die "unknown mode: $MODE" ;;
esac
