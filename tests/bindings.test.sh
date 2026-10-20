#!/bin/bash
# tests/bindings.test.sh — prefix+r reload 绑定、原绑定保存、Escape 冲突告警
#
# 覆盖 PR-C 的键绑定面：
#   - 每次加载重绑 reload 绑定（自愈；不再依赖一次性哨兵）
#   - 用户原 prefix+r 绑定保存到 @claude_hooks_saved_bind_r 且不被覆盖
#   - 既有全局 Escape 绑定保存 + 一次性告警
#   - scripts/tmux-ai-reload：按 #{config_files} 只 source 存在的文件 + 重跑入口
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

ENTRY="$ROOT/tmux-ai-hooks-status.tmux"
RELOAD="$ROOT/scripts/tmux-ai-reload"

mkdir -p "$TEST_TMP/home" "$TEST_TMP/tmux"
export HOME="$TEST_TMP/home"
export FAKE_TMUX_DIR="$TEST_TMP/tmux"
export TMUX_AI_SUPPRESS_DIR="$HOME/.config/tmuxclihook"
unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR XDG_CONFIG_HOME || true

calls() { command cat "$FAKE_TMUX_DIR/calls.log" 2>/dev/null || true; }
assert_contains() { case "$2" in *"$1"*) ;; *) printf 'FAIL: %s: 未包含 %s（log: %s）\n' "$3" "$1" "$2" >&2; exit 1 ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) printf 'FAIL: %s: 不应包含 %s\n' "$3" "$1" >&2; exit 1 ;; esac; }
assert_eq() { [ "$2" = "$1" ] || { printf 'FAIL: %s: expected [%s], got [%s]\n' "$3" "$1" "${2:-}" >&2; exit 1; }; }

# ── fake tmux：记录全部调用；最小状态机 ──
tmux() {
    printf '%s\n' "$*" >> "$FAKE_TMUX_DIR/calls.log"
    case "${1:-}" in
        show-option)
            case "${3:-}" in
                @claude_hooks_status_color) echo "#F1FA8C" ;;
                status) echo "on" ;;
                @claude_hooks_saved_bind_r) [ -f "$FAKE_TMUX_DIR/saved_r" ] && command cat "$FAKE_TMUX_DIR/saved_r" ;;
                @claude_hooks_saved_bind_escape) [ -f "$FAKE_TMUX_DIR/saved_esc" ] && command cat "$FAKE_TMUX_DIR/saved_esc" ;;
                @claude_hooks_esc_warned) [ -f "$FAKE_TMUX_DIR/esc_warned" ] && command cat "$FAKE_TMUX_DIR/esc_warned" ;;
                *) echo "" ;;
            esac
            ;;
        set-option)
            case "${2:-}" in
                -g)
                    case "${3:-}" in
                        @claude_hooks_saved_bind_r) printf '%s' "${4:-}" > "$FAKE_TMUX_DIR/saved_r" ;;
                        @claude_hooks_saved_bind_escape) printf '%s' "${4:-}" > "$FAKE_TMUX_DIR/saved_esc" ;;
                        @claude_hooks_esc_warned) printf '%s' "${4:-}" > "$FAKE_TMUX_DIR/esc_warned" ;;
                    esac
                    ;;
            esac
            ;;
        list-keys)
            case "$*" in
                *"-n Escape"*) [ -n "${FAKE_ESC_BIND:-}" ] && printf '%s\n' "$FAKE_ESC_BIND" ;;
                *"-T prefix r"*) [ -n "${FAKE_R_BIND:-}" ] && printf '%s\n' "$FAKE_R_BIND" ;;
            esac
            ;;
        display-message)
            case "$*" in
                *'#{config_files}'*) printf '%s\n' "${FAKE_CONFIG_FILES:-}" ;;
                *) echo "" ;;
            esac
            ;;
        source-file) ;;
        run-shell) ;;
        bind-key) ;;
        *) ;;
    esac
    return 0
}
export -f tmux

run_entry() { : > "$FAKE_TMUX_DIR/calls.log"; bash "$ENTRY" >/dev/null 2>&1; }

# ── 1: 首次加载——用户已有 prefix+r 绑定 → 保存 + 重绑到 reload helper ──
USER_R='bind-key    -T prefix r       source-file /home/u/.tmux.conf \; display-message 原重载'
FAKE_R_BIND="$USER_R" FAKE_ESC_BIND="" run_entry
assert_eq "$USER_R" "$(command cat "$FAKE_TMUX_DIR/saved_r" 2>/dev/null)" "原 prefix+r 绑定保存"
log=$(calls)
assert_contains "bind-key r run-shell '${ROOT}/scripts/tmux-ai-reload'" "$log" "reload 绑定指向 helper"
assert_not_contains "@claude_hooks_reload_registered" "$log" "不再使用一次性哨兵（自愈）"

# ── 2: 第二次加载（当前绑定已是本插件）→ 不覆盖已保存的原绑定 ──
FAKE_R_BIND="bind-key    -T prefix r       run-shell '${ROOT}/scripts/tmux-ai-reload'" run_entry
assert_eq "$USER_R" "$(command cat "$FAKE_TMUX_DIR/saved_r" 2>/dev/null)" "二次加载不覆盖已存原绑定"
assert_not_contains "set-option -g @claude_hooks_saved_bind_r" "$(calls)" "二次加载不再写保存"

# ── 3: 旧版插件保护绑定（含入口名）→ 不当作用户原绑定保存 ──
rm -f "$FAKE_TMUX_DIR/saved_r"
FAKE_R_BIND="bind-key    -T prefix r       source-file /home/u/.tmux.conf \; run-shell '${ROOT}/tmux-ai-hooks-status.tmux'" run_entry
[ ! -f "$FAKE_TMUX_DIR/saved_r" ] || { echo "FAIL: 自家旧版绑定被误存为用户原绑定" >&2; exit 1; }

# ── 4: 无既有 Escape 绑定 → 不保存不告警 ──
rm -f "$FAKE_TMUX_DIR/saved_esc" "$FAKE_TMUX_DIR/esc_warned"
FAKE_R_BIND="" FAKE_ESC_BIND="" run_entry
[ ! -f "$FAKE_TMUX_DIR/saved_esc" ] || { echo "FAIL: 无既有 Escape 绑定却写了保存" >&2; exit 1; }
[ ! -f "$FAKE_TMUX_DIR/esc_warned" ] || { echo "FAIL: 无冲突却告警" >&2; exit 1; }

# ── 5: 已有 Escape 绑定 → 保存 + 一次性告警（二次加载不重复）──
USER_ESC='bind-key    -n Escape    send-keys -t %1 C-c'
FAKE_R_BIND="" FAKE_ESC_BIND="$USER_ESC" run_entry
assert_eq "$USER_ESC" "$(command cat "$FAKE_TMUX_DIR/saved_esc" 2>/dev/null)" "原 Escape 绑定保存"
assert_eq "1" "$(command cat "$FAKE_TMUX_DIR/esc_warned" 2>/dev/null)" "告警标记写入"
log=$(calls)
assert_contains "覆盖了全局 Esc 绑定" "$log" "首次冲突告警"
FAKE_R_BIND="" FAKE_ESC_BIND="$USER_ESC" run_entry
assert_eq "0" "$(grep -c "覆盖了全局 Esc 绑定" "$FAKE_TMUX_DIR/calls.log" || true)" "二次加载不重复告警"
assert_eq "$USER_ESC" "$(command cat "$FAKE_TMUX_DIR/saved_esc" 2>/dev/null)" "二次加载不覆盖已存 Escape 绑定"

# ── 6: reload helper——只 source 存在的配置文件，然后重跑入口 ──
EXIST_CFG="$TEST_TMP/exists.conf"; : > "$EXIST_CFG"
: > "$FAKE_TMUX_DIR/calls.log"
FAKE_CONFIG_FILES="/nonexistent/a.conf,$EXIST_CFG" bash "$RELOAD" >/dev/null 2>&1
log=$(calls)
assert_contains "source-file $EXIST_CFG" "$log" "helper sources 存在的配置"
assert_not_contains "source-file /nonexistent/a.conf" "$log" "helper 跳过不存在的候选"
assert_contains "run-shell ${ROOT}/tmux-ai-hooks-status.tmux" "$log" "helper 重跑插件入口"
assert_contains "配置已重载" "$log" "helper 提示重载完成"

# ── 7: helper——config_files 为空时回落 ~/.tmux.conf ──
: > "$TEST_TMP/home/.tmux.conf"
: > "$FAKE_TMUX_DIR/calls.log"
FAKE_CONFIG_FILES="" bash "$RELOAD" >/dev/null 2>&1
assert_contains "source-file $HOME/.tmux.conf" "$(calls)" "落回 ~/.tmux.conf"

printf 'PASS: bindings 用例全部通过\n'
