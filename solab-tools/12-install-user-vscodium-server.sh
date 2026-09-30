#!/usr/bin/env bash
set -euo pipefail

COMMIT="4c0b0c6cc561d2d3636d1ec250935431876ce4dc"
ARCHIVE="/shared/models/vscodium-reh-linux-x64-1.126.04524.tar.gz"
INSTALL_DIR="$HOME/.vscodium-server/bin/$COMMIT"
LOCK="/run/user/$(id -u)/server_install.lock"

# 结束卡住的下载/安装进程并释放锁
fuser -k "$LOCK" 2>/dev/null || true
sleep 1
rm -f "$LOCK"

# 检查压缩包
test -f "$ARCHIVE" || {
    echo "错误：找不到 $ARCHIVE"
    exit 1
}
tar -tzf "$ARCHIVE" >/dev/null || {
    echo "错误：压缩包损坏或不完整"
    exit 1
}

# 清理不完整安装并手动解压
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

# 设置执行权限并验证
chmod +x "$INSTALL_DIR/node"
chmod +x "$INSTALL_DIR/bin/codium-server"

test -x "$INSTALL_DIR/bin/codium-server" || {
    echo "错误：未找到 bin/codium-server"
    exit 1
}

echo "安装完成：$INSTALL_DIR"
ls -l "$INSTALL_DIR/bin/codium-server"