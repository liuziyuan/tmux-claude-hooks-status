#!/bin/bash
# lib-install-hooks.sh — hooks 安装公共骨架
#
# 被 install-<tool>-hooks.sh wrapper source。提供工具无关的依赖检查与原子写；
# 工具特定的 jq 合并逻辑在各 adapter 的 adapter_install_hooks/adapter_uninstall_hooks 中。
#
# 契约：wrapper source 本文件 + adapters/<tool>.sh 后，调 adapter_install_hooks 或
# adapter_uninstall_hooks。adapter 的 install 函数用 _install_require_jq / _install_atomic_write。

# 依赖检查：jq 是唯一硬依赖
_install_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required. Install with: brew install jq" >&2
        exit 1
    fi
}

# 原子写入：mktemp 与目标同目录 → 同文件系统 → mv 原子。
# 避免与 AI CLI 并发写产生竞态导致 hooks 字段丢失。
_install_atomic_write() {
    local content="$1" target="$2" tmp
    mkdir -p "$(dirname "$target")" 2>/dev/null || true
    tmp=$(mktemp "$(dirname "$target")/.hooks.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$target"
}
