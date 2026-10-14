#!/bin/bash
# install-opencode-hooks.sh — opencode plugin 安装/卸载/检查 wrapper
# 用法: install-opencode-hooks.sh [install|uninstall|check]
#
# 薄 wrapper：source 公共骨架 + opencode adapter，dispatch 到 adapter_install_hooks /
# adapter_uninstall_hooks。实际逻辑在 scripts/adapters/opencode.sh。
# check：输出 ok/missing（exit 0/1），供 TUI 侦测走 bash 侧完整性判定。
# 显式 uninstall 成功写标记、显式 install 成功清标记（见 lib-install-hooks.sh）。

set -o errexit
set -o pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_LIB_DIR}/lib-install-hooks.sh"
source "${_LIB_DIR}/adapters/opencode.sh"

case "${1:-install}" in
    uninstall)
        adapter_uninstall_hooks
        _hooks_suppress_write opencode
        ;;
    check)
        if adapter_check_integrity; then
            echo ok
        else
            echo missing
            exit 1
        fi
        ;;
    *)
        adapter_install_hooks
        _hooks_suppress_clear opencode
        ;;
esac
