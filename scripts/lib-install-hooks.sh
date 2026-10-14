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

# --- 卸载意图标记（suppression marker）---
# 显式 uninstall 成功 → 写 suppressed-<tool>；显式 install 成功 → 清。
# 自动修复路径（_maybe_repair_hooks / 入口 auto / SessionStart 重装）见标记一律不装。
# ⚠️ _SUPPRESS_DIR 与 lib-tmux-ai-status.sh 中的定义保持一致（两处同步改）。
_SUPPRESS_DIR="${TMUX_AI_SUPPRESS_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/tmuxclihook}"

_hooks_suppress_file() { printf '%s/suppressed-%s' "$_SUPPRESS_DIR" "$1"; }
_hooks_suppress_write() {
    mkdir -p "$_SUPPRESS_DIR" 2>/dev/null || true
    date +%s > "$(_hooks_suppress_file "$1")" 2>/dev/null || true
}
_hooks_suppress_clear() { rm -f "$(_hooks_suppress_file "$1")" 2>/dev/null || true; }
