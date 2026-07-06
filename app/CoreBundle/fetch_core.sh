#!/bin/bash
# Mole for Mac - 内嵌核心构建脚本（设计 §12 步骤 1）。
# 按 core.lock 把 CLI 核心（mole 入口 + bin/ + lib/ + 两个 Go 二进制）
# 装配到 app/Resources/mole-core/，并生成 SHA256 清单供运行时校验（§7.5）。
#
# monorepo 阶段（core.lock: source=worktree）直接使用本仓库工作树；
# 拆分独立仓库后（source=git）改为按 ref 克隆导出。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"
DEST="$APP_DIR/Resources/mole-core"

lock_value() {
    sed -n "s/^$1: //p" "$SCRIPT_DIR/core.lock" | head -1
}

SOURCE_MODE="$(lock_value source)"
if [[ "$SOURCE_MODE" != "worktree" ]]; then
    echo "source=$SOURCE_MODE not implemented yet; use worktree during monorepo phase" >&2
    exit 1
fi

echo "==> Building Go binaries (make build)"
(cd "$REPO_ROOT" && make build)

echo "==> Staging core into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

cp "$REPO_ROOT/mole" "$DEST/mole"
cp -R "$REPO_ROOT/bin" "$DEST/bin"
cp -R "$REPO_ROOT/lib" "$DEST/lib"

for bin in analyze-go status-go; do
    if [[ -x "$REPO_ROOT/bin/$bin" ]]; then
        cp "$REPO_ROOT/bin/$bin" "$DEST/$bin"
    elif [[ -x "$REPO_ROOT/$bin" ]]; then
        cp "$REPO_ROOT/$bin" "$DEST/$bin"
    else
        echo "warning: $bin not found after make build; status/analyze features will be unavailable" >&2
    fi
done

echo "==> Writing SHA256 manifest"
(cd "$DEST" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$APP_DIR/Resources/mole-core.sha256")

echo "==> Done. Core staged at $DEST"
