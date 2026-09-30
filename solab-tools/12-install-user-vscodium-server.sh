#!/usr/bin/env bash
# Install a VSCodium remote server for the current user from a local archive,
# without downloading anything. Works for any VSCodium version.
#
# Usage:
#   bash 12-install-user-vscodium-server.sh [ARCHIVE] [COMMIT]
#
#   ARCHIVE  vscodium-reh-linux-<arch>-<version>.tar.gz
#            default: newest vscodium-reh-linux-*.tar.gz in /shared/models
#   COMMIT   40-hex commit of the connecting client (VSCodium Help > About)
#            default: the commit recorded in the archive's product.json
#
# The server directory is named after the commit, and the client only reuses a
# server whose directory matches its own commit exactly. If the client keeps
# re-downloading after this runs, pass COMMIT explicitly from Help > About.
set -euo pipefail

ARCHIVE="${1:-}"
COMMIT="${2:-}"

if [[ -z "$ARCHIVE" ]]; then
    ARCHIVE="$(ls -t /shared/models/vscodium-reh-linux-*.tar.gz 2>/dev/null | head -1 || true)"
    [[ -n "$ARCHIVE" ]] || { echo "错误：未指定压缩包，且 /shared/models 下没有 vscodium-reh-linux-*.tar.gz" >&2; exit 1; }
fi
[[ -f "$ARCHIVE" ]] || { echo "错误：找不到 $ARCHIVE" >&2; exit 1; }
tar -tzf "$ARCHIVE" >/dev/null || { echo "错误：压缩包损坏或不完整" >&2; exit 1; }

# Top-level product.json, i.e. one path component deep, matching --strip-components=1.
if [[ -z "$COMMIT" ]]; then
    PJ="$(tar -tzf "$ARCHIVE" | awk -F/ 'NF==2 && $2=="product.json"' | head -1)"
    [[ -n "$PJ" ]] && COMMIT="$(tar -xzOf "$ARCHIVE" "$PJ" | grep -o '"commit"[[:space:]]*:[[:space:]]*"[0-9a-f]\{40\}"' | grep -o '[0-9a-f]\{40\}' | head -1 || true)"
    [[ -n "$COMMIT" ]] || { echo "错误：无法从压缩包读取 commit，请作为第二个参数传入（Help > About 中的 Commit）" >&2; exit 1; }
    SRC="product.json"
else
    SRC="参数"
fi
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "错误：commit 必须是 40 位十六进制：$COMMIT" >&2; exit 1; }

INSTALL_DIR="$HOME/.vscodium-server/bin/$COMMIT"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/server_install.lock"
echo "压缩包：$ARCHIVE"
echo "Commit：$COMMIT（来自$SRC）"

# 结束卡住的下载/安装进程并释放锁
fuser -k "$LOCK" 2>/dev/null || true
sleep 1
rm -f "$LOCK"

# 清理不完整安装并解压
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

chmod +x "$INSTALL_DIR/node" "$INSTALL_DIR/bin/codium-server"
test -x "$INSTALL_DIR/bin/codium-server" || { echo "错误：未找到 bin/codium-server" >&2; exit 1; }

echo "安装完成：$INSTALL_DIR"
ls -l "$INSTALL_DIR/bin/codium-server"
