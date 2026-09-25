#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Repair a remote user's VSCodium server from any solab host.
set -euo pipefail

# OpenSSH invokes this mode to obtain the password without storing it on disk.
if [[ "${SOLAB_VSCODIUM_ASKPASS_MODE:-}" == "1" ]]; then
    printf '%s\n' "${SOLAB_VSCODIUM_PASSWORD:?}"
    exit 0
fi

# This script used to refuse to run anywhere but s1. s1 was never actually
# required: it is simply the host that owns /shared and had the lab CA
# installed. What the script really needs is one of
#   - the archive already present in /shared/models, which
#     05-setup-s1-shared-storage.sh mounts on every client, or
#   - working HTTPS to GitHub, which needs the CA that
#     01-install-ca-to-fix-https-download-errors.sh installs, because the lab
#     inspects TLS.
# Both are checked where they are used, so any host that satisfies either one
# can run this.
SHARED_DIR="${VSCODIUM_SHARED_DIR:-/shared/models}"
ARCHIVE_OVERRIDE="${VSCODIUM_ARCHIVE:-}"

for REQUIRED_COMMAND in ssh scp curl sha1sum awk tar readlink mktemp; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || {
        echo "Error: Missing required command $REQUIRED_COMMAND." >&2
        exit 1
    }
done

printf 'Please enter the IP address of the server to repair: '
IFS= read -r TARGET_IP
if [[ ! "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Please enter a valid IPv4 address." >&2
    exit 1
fi
IFS=. read -r -a IP_PARTS <<< "$TARGET_IP"
for IP_PART in "${IP_PARTS[@]}"; do
    if ((10#$IP_PART > 255)); then
        echo "Error: Please enter a valid IPv4 address." >&2
        exit 1
    fi
done

# Repairing the host you are sitting on would scp a file to itself and race the
# running server against its own reinstall.
for LOCAL_IP in $(hostname -I 2>/dev/null || true); do
    if [[ "$LOCAL_IP" == "$TARGET_IP" ]]; then
        echo "Error: $TARGET_IP is this machine ($(hostname -s))." >&2
        echo "Run the local installer on the target instead." >&2
        exit 1
    fi
done

printf 'Please enter the SSH port [22]: '
IFS= read -r TARGET_PORT
TARGET_PORT="${TARGET_PORT:-22}"
if [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] || [[ "${#TARGET_PORT}" -gt 5 ]] ||
    ((10#$TARGET_PORT < 1 || 10#$TARGET_PORT > 65535)); then
    echo "Error: SSH port must be an integer between 1-65535." >&2
    exit 1
fi

printf 'Please enter the SSH username: '
IFS= read -r TARGET_USER
if [[ ! "$TARGET_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*[$]?$ ]]; then
    echo "Error: Invalid SSH username format." >&2
    exit 1
fi

printf 'Please enter the SSH password (input will not be displayed): '
IFS= read -rs TARGET_PASSWORD
printf '\n'
if [[ -z "$TARGET_PASSWORD" ]]; then
    echo "Error: SSH password cannot be empty." >&2
    exit 1
fi

DOWNLOADED_ARCHIVE=""
REMOTE_ARCHIVE=""
ASKPASS_HELPER=""
TARGET="${TARGET_USER}@${TARGET_IP}"
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"

# OpenSSH execs SSH_ASKPASS, so it has to carry the execute bit. Invoking this
# file as "bash script.sh", or copying it around without preserving the mode,
# leaves it non-executable - and then the password prompt fails on exactly the
# hosts this change is meant to support. Fall back to a private helper.
if [[ -x "$SCRIPT_PATH" ]]; then
    ASKPASS_PATH="$SCRIPT_PATH"
else
    ASKPASS_HELPER="$(mktemp /tmp/vscodium-askpass.XXXXXXXX)"
    chmod 700 -- "$ASKPASS_HELPER"
    cat > "$ASKPASS_HELPER" <<'ASKPASS'
#!/usr/bin/env bash
printf '%s\n' "${SOLAB_VSCODIUM_PASSWORD:?}"
ASKPASS
    ASKPASS_PATH="$ASKPASS_HELPER"
fi

SSH_COMMON_OPTIONS=(
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -o NumberOfPasswordPrompts=1
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password,keyboard-interactive
)
SSH_OPTIONS=(-p "$TARGET_PORT" "${SSH_COMMON_OPTIONS[@]}")
SCP_OPTIONS=(-P "$TARGET_PORT" "${SSH_COMMON_OPTIONS[@]}")

run_ssh() {
    SOLAB_VSCODIUM_ASKPASS_MODE=1 \
        SOLAB_VSCODIUM_PASSWORD="$TARGET_PASSWORD" \
        SSH_ASKPASS="$ASKPASS_PATH" \
        SSH_ASKPASS_REQUIRE=force \
        DISPLAY=solab-vscodium \
        ssh "${SSH_OPTIONS[@]}" "$@"
}

run_scp() {
    SOLAB_VSCODIUM_ASKPASS_MODE=1 \
        SOLAB_VSCODIUM_PASSWORD="$TARGET_PASSWORD" \
        SSH_ASKPASS="$ASKPASS_PATH" \
        SSH_ASKPASS_REQUIRE=force \
        DISPLAY=solab-vscodium \
        scp "${SCP_OPTIONS[@]}" "$@"
}

cleanup() {
    local exit_code=$?
    if [[ -n "$REMOTE_ARCHIVE" ]]; then
        run_ssh "$TARGET" rm -f -- "$REMOTE_ARCHIVE" >/dev/null 2>&1 || true
    fi
    # Only ever remove the copy this run downloaded. The shared copy and any
    # archive named by VSCODIUM_ARCHIVE belong to someone else.
    if [[ -n "$DOWNLOADED_ARCHIVE" ]]; then
        rm -f -- "$DOWNLOADED_ARCHIVE"
    fi
    if [[ -n "$ASKPASS_HELPER" ]]; then
        rm -f -- "$ASKPASS_HELPER"
    fi
    unset TARGET_PASSWORD
    trap - EXIT
    exit "$exit_code"
}
trap cleanup EXIT

echo "Please click Help > About in the VSCodium that needs to connect to this server."
echo "Please paste the complete About information, then press Enter again to finish:"
VERSION=""
COMMIT=""
while IFS= read -r ABOUT_LINE; do
    ABOUT_LINE="${ABOUT_LINE%$'\r'}"
    [[ -n "$ABOUT_LINE" ]] || break

    if [[ "$ABOUT_LINE" =~ ^[[:space:]]*Version:[[:space:]]*([0-9]+(\.[0-9]+)+)([[:space:]].*)?$ ]]; then
        VERSION="${BASH_REMATCH[1]}"
    elif [[ "$ABOUT_LINE" =~ ^[[:space:]]*Commit:[[:space:]]*([0-9a-fA-F]{40})[[:space:]]*$ ]]; then
        COMMIT="${BASH_REMATCH[1],,}"
    elif [[ "$ABOUT_LINE" =~ ^[[:space:]]*Commit:[[:space:]]*(.*)$ ]] &&
        [[ -n "${BASH_REMATCH[1]//[[:space:]]/}" ]]; then
        echo "Error: Commit in About information is not a valid 40-character hexadecimal value." >&2
        exit 1
    fi
done

if [[ -z "$VERSION" ]]; then
    echo "Error: Unable to extract version number from About information." >&2
    exit 1
fi

if [[ -n "$COMMIT" ]]; then
    COMMIT_SOURCE="About information"
else
    COMMIT="$(printf '%s\n' "$VERSION" | sha1sum | awk '{print $1}')"
    COMMIT_SOURCE="Calculated from version number"
fi
ARCHIVE_NAME="vscodium-reh-linux-x64-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/VSCodium/vscodium/releases/download/${VERSION}/${ARCHIVE_NAME}"
SHARED_ARCHIVE="${SHARED_DIR}/${ARCHIVE_NAME}"

echo "VSCodium Version: $VERSION"
echo "VSCodium Commit: $COMMIT ($COMMIT_SOURCE)"
echo "Running from: $(hostname -s)"
echo "Target Server: ${TARGET}:${TARGET_PORT}"

# ---- obtain the archive ----------------------------------------------------
# Order matters: the share is checked before the network, so on a lab host the
# download never happens at all. That is what removes the dependency on this
# being s1.
if [[ -n "$ARCHIVE_OVERRIDE" ]]; then
    [[ -f "$ARCHIVE_OVERRIDE" ]] || {
        echo "Error: VSCODIUM_ARCHIVE does not exist: $ARCHIVE_OVERRIDE" >&2
        exit 1
    }
    SOURCE_ARCHIVE="$ARCHIVE_OVERRIDE"
    echo "Archive: $SOURCE_ARCHIVE (VSCODIUM_ARCHIVE)"
elif [[ -f "$SHARED_ARCHIVE" ]]; then
    SOURCE_ARCHIVE="$SHARED_ARCHIVE"
    echo "Archive: $SOURCE_ARCHIVE (shared storage, no download needed)"
else
    echo "Archive: not in ${SHARED_DIR}, downloading from $DOWNLOAD_URL"
    DOWNLOADED_ARCHIVE="$(mktemp /tmp/vscodium-server-download.XXXXXXXX.tar.gz)"
    if ! curl --fail --location --show-error \
        --proto '=https' --proto-redir '=https' \
        --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 1200 \
        --output "$DOWNLOADED_ARCHIVE" "$DOWNLOAD_URL"; then
        echo "Error: Download failed on $(hostname -s)." >&2
        echo "  The lab inspects TLS, so HTTPS fails until the CA is installed:" >&2
        echo "    bash 01-install-ca-to-fix-https-download-errors.sh" >&2
        echo "  Or place the archive on the share and rerun:" >&2
        echo "    ${SHARED_ARCHIVE}" >&2
        echo "  Or point at a local copy:" >&2
        echo "    VSCODIUM_ARCHIVE=/path/to/${ARCHIVE_NAME} bash $(basename -- "$SCRIPT_PATH")" >&2
        exit 1
    fi
    SOURCE_ARCHIVE="$DOWNLOADED_ARCHIVE"
fi

tar -tzf "$SOURCE_ARCHIVE" >/dev/null || {
    echo "Error: Archive is corrupted or incomplete: $SOURCE_ARCHIVE" >&2
    exit 1
}

# The install directory is named after the CLIENT's commit, so a mismatched
# archive still lands where the client looks and still gets found - the client
# then refuses it with "version mismatch" after the connection is already up.
# That failure points at the server, not at the archive, so check it here where
# the cause is still obvious.
ARCHIVE_PRODUCT="$(tar -xzOf "$SOURCE_ARCHIVE" --wildcards 'vscodium-reh-*/product.json' 2>/dev/null || true)"
if [[ -n "$ARCHIVE_PRODUCT" ]]; then
    ARCHIVE_VERSION="$(printf '%s' "$ARCHIVE_PRODUCT" |
        grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 |
        sed 's/.*"\([^"]*\)"$/\1/')"
    ARCHIVE_COMMIT="$(printf '%s' "$ARCHIVE_PRODUCT" |
        grep -oE '"commit"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' | head -1 |
        grep -oE '[0-9a-fA-F]{40}' | tr '[:upper:]' '[:lower:]')"

    if [[ -n "$ARCHIVE_VERSION" && "$ARCHIVE_VERSION" != "$VERSION" ]]; then
        echo "Error: Archive is VSCodium $ARCHIVE_VERSION, but the client is $VERSION." >&2
        echo "  Archive: $SOURCE_ARCHIVE" >&2
        echo "  Installing it would succeed and the client would then refuse the" >&2
        echo "  connection with 'version mismatch'." >&2
        echo "  Get the matching build:" >&2
        echo "    https://github.com/VSCodium/vscodium/releases/download/${VERSION}/${ARCHIVE_NAME}" >&2
        exit 1
    fi
    if [[ -n "$ARCHIVE_COMMIT" && "$COMMIT_SOURCE" == "About information" &&
        "$ARCHIVE_COMMIT" != "$COMMIT" ]]; then
        echo "Error: Archive commit $ARCHIVE_COMMIT does not match the client commit $COMMIT." >&2
        echo "  Archive: $SOURCE_ARCHIVE" >&2
        exit 1
    fi
    echo "Archive verified: VSCodium $ARCHIVE_VERSION (commit ${ARCHIVE_COMMIT:-unknown})"
else
    echo "Warning: could not read product.json from the archive; version not verified." >&2
fi

# Publish a freshly downloaded archive so the next host, and the next user,
# take the share path above instead of downloading it again. Best effort: the
# share is read-only for some accounts and that must not fail the repair.
if [[ -n "$DOWNLOADED_ARCHIVE" && -d "$SHARED_DIR" && -w "$SHARED_DIR" && ! -e "$SHARED_ARCHIVE" ]]; then
    SHARED_TMP="$(mktemp "${SHARED_DIR}/.vscodium-publish.XXXXXXXX" 2>/dev/null || true)"
    if [[ -n "$SHARED_TMP" ]] && cp -- "$DOWNLOADED_ARCHIVE" "$SHARED_TMP" 2>/dev/null &&
        chmod 0644 -- "$SHARED_TMP" 2>/dev/null &&
        mv -n -- "$SHARED_TMP" "$SHARED_ARCHIVE" 2>/dev/null; then
        echo "Cached on the share for the next run: $SHARED_ARCHIVE"
    else
        [[ -n "$SHARED_TMP" ]] && rm -f -- "$SHARED_TMP"
    fi
fi

echo "Connecting to target server and creating temporary file..."
REMOTE_ARCHIVE="$(run_ssh "$TARGET" mktemp /tmp/vscodium-server.XXXXXXXX.tar.gz)"
if [[ ! "$REMOTE_ARCHIVE" =~ ^/tmp/vscodium-server\.[A-Za-z0-9]{8}\.tar\.gz$ ]]; then
    echo "Error: Target server returned an invalid temporary file path." >&2
    exit 1
fi

echo "Transferring VSCodium Server archive via intranet..."
run_scp "$SOURCE_ARCHIVE" "${TARGET}:${REMOTE_ARCHIVE}"

echo "Installing on target server..."
run_ssh "$TARGET" bash -s -- "$COMMIT" "$REMOTE_ARCHIVE" <<'REMOTE_SCRIPT'
set -euo pipefail

commit="$1"
archive="$2"
install_dir="$HOME/.vscodium-server/bin/$commit"
lock="/run/user/$(id -u)/server_install.lock"

cleanup_remote_archive() {
    rm -f -- "$archive"
}
trap cleanup_remote_archive EXIT

[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Error: Invalid server directory hash." >&2
    exit 1
}
test -f "$archive" || {
    echo "Error: Transferred archive not found." >&2
    exit 1
}
tar -tzf "$archive" >/dev/null || {
    echo "Error: Transferred archive is corrupted or incomplete." >&2
    exit 1
}

if command -v fuser >/dev/null 2>&1; then
    fuser -k "$lock" 2>/dev/null || true
    sleep 1
fi
rm -f -- "$lock"

rm -rf -- "$install_dir"
mkdir -p -- "$install_dir"
tar -xzf "$archive" -C "$install_dir" --strip-components=1
chmod +x "$install_dir/node" "$install_dir/bin/codium-server"

test -x "$install_dir/bin/codium-server" || {
    echo "Error: bin/codium-server not found." >&2
    exit 1
}

echo "Installation complete: $install_dir"
ls -l "$install_dir/bin/codium-server"
REMOTE_SCRIPT

REMOTE_ARCHIVE=""
echo "Repair complete: ${TARGET}:${TARGET_PORT}"
