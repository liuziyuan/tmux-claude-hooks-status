#!/bin/bash
# install-claude-hooks.sh — Claude Code hooks 安装/卸载/检查 wrapper
# 用法: install-claude-hooks.sh [uninstall|check]
#
# 薄 wrapper：source 公共骨架 + claude adapter，dispatch 到 adapter_install_hooks /
# adapter_uninstall_hooks。实际逻辑在 scripts/adapters/claude.sh。
# check：输出 ok/missing（exit 0/1），供 TUI 侦测在 cc-switch 模式下走 bash 侧
# 完整性判定（sqlite 真源），与非 cc-switch 的文件判定共用同一真相。

set -o errexit
set -o pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_LIB_DIR}/lib-install-hooks.sh"
source "${_LIB_DIR}/adapters/claude.sh"

if [ "${1:-install}" = "uninstall" ]; then
    adapter_uninstall_hooks
elif [ "${1:-}" = "check" ]; then
    if adapter_check_integrity; then
        echo ok
    else
        echo missing
        exit 1
    fi
else
    adapter_install_hooks
fi
