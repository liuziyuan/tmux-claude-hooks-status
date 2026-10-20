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
#
# 失败语义（两个方向都告警，不对称）：
# - write 失败：hooks 已剥离但标记没落 → auto 会静默装回（用户显式卸载被反转）
#   → return 1，wrapper uninstall 分支 errexit 使其以非 0 退出，用户可见。
# - clear 失败：install 已成功但残留标记会把 auto 永久挡住（比 write 失败更隐蔽）
#   → 告警但 return 0（主操作已成功，调用方 wrapper 的 clear 调用需 || true 容忍）。
_SUPPRESS_DIR="${TMUX_AI_SUPPRESS_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/tmuxclihook}"

_hooks_suppress_file() { printf '%s/suppressed-%s' "$_SUPPRESS_DIR" "$1"; }
_hooks_suppress_write() {
    if ! mkdir -p "$_SUPPRESS_DIR" 2>/dev/null \
       || ! date +%s > "$(_hooks_suppress_file "$1")" 2>/dev/null; then
        echo "WARN: 抑制标记写入失败——hooks 已卸载，但 tmux 重载/新会话可能自动装回；" \
             "请检查 $_SUPPRESS_DIR 可写性" >&2
        return 1
    fi
}
_hooks_suppress_clear() {
    if [ -e "$(_hooks_suppress_file "$1")" ] \
       && ! rm -f "$(_hooks_suppress_file "$1")" 2>/dev/null; then
        echo "WARN: 卸载意图标记清除失败——tmux 自动安装将持续跳过；" \
             "请检查 $_SUPPRESS_DIR 可写性" >&2
        return 1
    fi
}

# --- check --json：完整性明细 JSON（wrapper 专用，事件热路径不触达）---
# stdout = 单行紧凑 JSON；exit code 与默认 check 一致（ok→0 / missing→1）。
# status 判定复用 adapter_check_integrity 本体（同一真源，与 ok/missing 永不发散）；
# suppress 在 wrapper 层判定（adapter 双上下文不依赖本文件，见各 adapter 头注释）；
# drift 参照系 = 执行中 wrapper 自身的 _LIB_DIR：Node 侧经 execa 调用的正是其解析出的
# SCRIPTS_DIR 下的 wrapper，故 _LIB_DIR 即当前 source 的 scripts dir；手动用旧 source
# 的 wrapper 跑 check 得到「相对该 source 无漂移」也是正确语义（它正是那个源的收敛执行者）。
_wrapper_check_json() {  # $1=tool id
    local tool="$1" status="missing" detail suppress
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"tool":"%s","status":"missing","mode":"unknown","suppress":false,"events":{},"plugin":null,"registeredPaths":[],"drift":{"drifted":false,"expected":"","currentScriptsDir":"%s","stale":[]},"error":"jq not found"}\n' "$tool" "$_LIB_DIR"
        exit 1
    fi
    detail=$(adapter_check_detail 2>/dev/null) || detail=""
    [ -n "$detail" ] || detail='{}'
    if adapter_check_integrity >/dev/null 2>&1; then
        status="ok"
    fi
    if [ -f "$(_hooks_suppress_file "$tool")" ]; then
        suppress="true"
    else
        suppress="false"
    fi
    jq -cn --arg tool "$tool" --arg status "$status" --argjson detail "$detail" \
        --argjson suppress "$suppress" --arg dir "$_LIB_DIR" '
        ($detail + {tool: $tool, status: $status, suppress: $suppress})
        | .drift = {
            expected: ($dir + "/tmux-ai-status"),
            currentScriptsDir: $dir,
            stale: (($detail.registeredPaths // [])
                    | map(select(. != ($dir + "/tmux-ai-status")) ) | unique)
          }
        | .drift.drifted = ((.drift.stale | length) > 0)'
    if [ "$status" != "ok" ]; then
        exit 1
    fi
}
