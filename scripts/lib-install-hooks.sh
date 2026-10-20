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

# 解析符号链接到最终真实路径（不要求目标存在——悬空链接同样要解析）。
# 相对链接基于链接所在目录解析；循环/超深链（>40 层）返回 1，调用方回退原路径。
# 用途：cc-switch 为每个 codex provider 建独立 CODEX_HOME，并把 hooks.json 做成
# 指向 ~/.codex/hooks.json 的符号链接（所有实例共享同一真源）。mv 作用于链接路径
# 时只替换链接本身，因此写入必须解析到真实目标，否则实例与共享真源分叉。
_install_real_target() {  # $1=路径 → stdout 最终路径
    local p="$1" link n=0
    while [ -L "$p" ]; do
        n=$((n + 1))
        [ "$n" -le 40 ] || return 1
        link=$(readlink "$p" 2>/dev/null) || return 1
        [ -n "$link" ] || return 1
        case "$link" in
            /*) p="$link" ;;
            *)  p="$(dirname "$p")/$link" ;;
        esac
    done
    printf '%s\n' "$p"
}

# 原子写入：mktemp 与真实目标同目录 → 同文件系统 → mv 原子。
# 避免与 AI CLI 并发写产生竞态导致 hooks 字段丢失。
# 符号链接先解析：临时文件建在真实目标目录，mv 写穿链接（保留链接本身）。
_install_atomic_write() {
    local content="$1" target="$2" tmp real
    real=$(_install_real_target "$target") || real="$target"
    mkdir -p "$(dirname "$real")" 2>/dev/null || true
    tmp=$(mktemp "$(dirname "$real")/.hooks.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$real"
}

# 删除写入目标（uninstall 清空时用）：符号链接解析后只删真实目标，保留链接
# （指向悬空，下次 install 写穿即恢复共享）。直接 rm 链接会删掉链接本身，把
# 共享真源留在原地——其他实例仍被注册，语义与「卸载」矛盾。
_install_remove_target() {  # $1=路径
    local target="$1" real
    real=$(_install_real_target "$target") || real="$target"
    rm -f "$real"
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

# --- 安装意图标记（installed marker）---
# 显式 install / claude auto（含已收敛跳过）→ 写；显式 uninstall → 删。
# 语义 = 用户装过该工具；跨工具自修复（_maybe_repair_other_tools）据此决定
# hooks 丢失时是否允许自动重装。无标记 + check 失败时绝不安装——尊重
# 「codex/opencode 非人人安装」的现状。
# ⚠️ 与 suppressed 同属 _SUPPRESS_DIR 两处同步约束（另一处见 lib-tmux-ai-status.sh）。
_hooks_installed_file() { printf '%s/installed-%s' "$_SUPPRESS_DIR" "$1"; }
_hooks_installed_write() {
    if ! mkdir -p "$_SUPPRESS_DIR" 2>/dev/null \
       || ! date +%s > "$(_hooks_installed_file "$1")" 2>/dev/null; then
        echo "WARN: 安装意图标记写入失败——该工具 hooks 丢失后不会自动修复；" \
             "请检查 $_SUPPRESS_DIR 可写性" >&2
        return 1
    fi
}
_hooks_installed_clear() {
    if [ -e "$(_hooks_installed_file "$1")" ] \
       && ! rm -f "$(_hooks_installed_file "$1")" 2>/dev/null; then
        echo "WARN: 安装意图标记删除失败（卸载仍由 suppressed 标记兜底）" >&2
        return 1
    fi
}
_hooks_installed_ensure() {  # 已登记则不动，避免 mtime 抖动
    [ -e "$(_hooks_installed_file "$1")" ] || _hooks_installed_write "$1"
}

# --- 安装/卸载读-改-写互斥锁 ---
# 写路径的并发方：TUI 显式装 / tmux 入口 auto / SessionStart 自修复 / _maybe_repair_hooks /
# drift 收敛——五方都经 wrapper dispatch，锁在此层一处覆盖三 adapter。
# mkdir mutex（项目风格同 .lock/.event-lock；macOS 无 flock(1)）。两种失败语义区分：
# - 锁目录建不出来（权限/ENOTDIR）→ 降级无锁继续 + 告警（历史行为是无锁写；install
#   真正写目标与锁目录不同权限域，锁失败不代表写不了）
# - 他人持锁 → 等待（0.2s × 50 ≈ 10s）→ stale（10s）强夺 → 超时报错 return 1（显式操作可见）。
#   ⚠️ codex SessionStart 是同步 hook（timeout:5s）：极端并发下锁等待可能超过 5s 使该次
#   hook 超时——后果轻（该次 hook 不执行、codex 继续、无阻塞），概率极低（repair 60s 一次）。
# 边界：锁只收敛「我们自己的多方」；Claude Code 自身写 settings.json 不遵守本锁（外部
# 写者无法防）——这正是 60s 自修复存在的原因。写路径互斥由 wrapper 层负责，adapter
# 函数不含锁——直接 source adapter 调 install 会绕过锁。
_install_lock_dir() { printf '%s/.install-lock-%s' "$_SUPPRESS_DIR" "$1"; }
_install_acquire_lock() {  # $1=tool id → 0=持锁 1=超时（2=降级无锁，调用方继续）
    local lock; lock=$(_install_lock_dir "$1")
    if ! mkdir -p "$_SUPPRESS_DIR" 2>/dev/null; then
        echo "WARN: 锁目录不可创建（$_SUPPRESS_DIR），降级无锁继续安装" >&2
        return 2
    fi
    local _start=$SECONDS i
    for i in {1..50}; do
        if mkdir "$lock" 2>/dev/null; then
            echo "$$" > "$lock/owner"
            return 0
        fi
        # stale 强夺：持锁者进程已死 → 立即夺；锁 mtime 超 10s → 强夺。
        # 外部命令（stat/sleep/rmdir）逐一防御退出码——ccswitch 用例 8 的 stubbin
        # 是最小 PATH 沙箱（无 stat/rmdir/sleep），127 会在 errexit 下炸掉 install。
        local owner mtime
        owner=$(cat "$lock/owner" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$lock/owner" 2>/dev/null || true
            rmdir "$lock" 2>/dev/null || true
            continue
        fi
        mtime=""
        mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || true)
        if [ -n "$mtime" ] && [ $(( _start + SECONDS - mtime )) -ge 10 ]; then
            echo "WARN: 强夺超时的安装锁（owner=${owner:-?}）" >&2
            rm -f "$lock/owner" 2>/dev/null || true
            rmdir "$lock" 2>/dev/null || true
            continue
        fi
        sleep 0.2 2>/dev/null || :
    done
    echo "ERROR: 安装锁获取超时（$lock）——另一安装操作可能仍在进行，稍后重试" >&2
    return 1
}
_install_release_lock() {  # $1=tool id
    local lock; lock=$(_install_lock_dir "$1")
    rm -f "$lock/owner" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
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
