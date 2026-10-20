#!/bin/bash
# install-codex-hooks.sh — Codex CLI hooks 安装/卸载/检查 wrapper（需 codex ≥ 0.144）
# 用法: install-codex-hooks.sh [install|uninstall|check [--json]]
#
# 薄 wrapper：source 公共骨架 + codex adapter，dispatch 到 adapter_install_hooks /
# adapter_uninstall_hooks。实际逻辑在 scripts/adapters/codex.sh。
# check：输出 ok/missing（exit 0/1），供 TUI 侦测走 bash 侧完整性判定。
# check --json：单行紧凑明细 JSON（mode/events/suppress/drift），同样 exit 0/1。
# 显式 uninstall 成功写标记、显式 install 成功清标记（见 lib-install-hooks.sh）。

set -o errexit
set -o pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_LIB_DIR}/lib-install-hooks.sh"
source "${_LIB_DIR}/adapters/codex.sh"

case "${1:-install}" in
    uninstall)
        adapter_uninstall_hooks
        _hooks_suppress_write codex
        ;;
    check)
        if [ "${2:-}" = "--json" ]; then
            _wrapper_check_json codex
        elif adapter_check_integrity; then
            echo ok
        else
            echo missing
            exit 1
        fi
        ;;
    *)
        adapter_install_hooks
        _hooks_suppress_clear codex || true
        ;;
esac
