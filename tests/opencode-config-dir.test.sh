#!/bin/bash
# tests/opencode-config-dir.test.sh — opencode 配置目录解析优先级
#
# 优先级（与 cc-switch 4.0 的 opencode 目录覆盖保持一致）：
#   OPENCODE_CONFIG_DIR > ~/.cc-switch/settings.json 的 opencodeConfigDir > XDG 默认
# 旧版 cc-switch 没有 opencodeConfigDir 键，必须回退默认目录（向后兼容）。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

unset OPENCODE_CONFIG_DIR XDG_CONFIG_HOME || true

# 在隔离 HOME 下 source adapter，输出解析出的 plugin 路径。
# 额外环境变量以 NAME=VALUE 形式追加（会覆盖上面的 -u 默认值）。
resolve_with() {  # $1=home [NAME=VALUE ...]
    local home="$1"
    shift
    env -u OPENCODE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" _LIB_DIR="$ROOT/scripts" "$@" \
        bash -c 'source "$0/scripts/adapters/opencode.sh"; printf "%s\n" "$ADAPTER_HOOKS_FILE"' "$ROOT"
}

assert_eq() {  # $1=expected $2=actual $3=ctx
    [ "$2" = "$1" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "$2" >&2; exit 1; }
}

# ── 1: 无任何覆盖 → XDG 默认（旧版 cc-switch / 非 cc-switch）──
H="$TEST_TMP/h-default"; mkdir -p "$H"
assert_eq "$H/.config/opencode/plugins/tmux-ai-status.ts" \
    "$(resolve_with "$H")" "默认目录"

# ── 2: OPENCODE_CONFIG_DIR 优先于 cc-switch 设置 ──
H="$TEST_TMP/h-env"; mkdir -p "$H/.cc-switch"
printf '{"opencodeConfigDir":"%s/settings-oc"}\n' "$H" > "$H/.cc-switch/settings.json"
assert_eq "$H/env-oc/plugins/tmux-ai-status.ts" \
    "$(resolve_with "$H" OPENCODE_CONFIG_DIR="$H/env-oc")" "env 优先"

# ── 3: cc-switch settings.opencodeConfigDir（支持 ~ 展开）──
H="$TEST_TMP/h-settings"; mkdir -p "$H/.cc-switch"
printf '{"opencodeConfigDir":"~/custom-opencode"}\n' > "$H/.cc-switch/settings.json"
assert_eq "$H/custom-opencode/plugins/tmux-ai-status.ts" \
    "$(resolve_with "$H")" "cc-switch 目录覆盖 + ~ 展开"

# ── 4: 绝对路径覆盖 ──
H="$TEST_TMP/h-abs"; mkdir -p "$H/.cc-switch"
printf '{"opencodeConfigDir":"%s/abs-oc"}\n' "$H" > "$H/.cc-switch/settings.json"
assert_eq "$H/abs-oc/plugins/tmux-ai-status.ts" \
    "$(resolve_with "$H")" "绝对路径覆盖"

# ── 5: XDG_CONFIG_HOME 生效（无覆盖时）──
H="$TEST_TMP/h-xdg"; mkdir -p "$H"
assert_eq "$H/xdg/opencode/plugins/tmux-ai-status.ts" \
    "$(resolve_with "$H" XDG_CONFIG_HOME="$H/xdg")" "XDG_CONFIG_HOME"

echo "PASS: opencode 配置目录解析用例全部通过"
