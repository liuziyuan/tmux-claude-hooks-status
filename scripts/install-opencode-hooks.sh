#!/bin/bash
# install-opencode-hooks.sh — opencode plugin 安装/卸载/检查 wrapper
# 用法: install-opencode-hooks.sh [install|uninstall|check [--json]]
#
# 薄 wrapper：source 公共骨架 + opencode adapter，dispatch 到 adapter_install_hooks /
# adapter_uninstall_hooks。实际逻辑在 scripts/adapters/opencode.sh。
# check：输出 ok/missing（exit 0/1），供 TUI 侦测走 bash 侧完整性判定。
# check --json：单行紧凑明细 JSON（mode/plugin/suppress/drift），同样 exit 0/1。
# 显式 uninstall 成功写标记、显式 install 成功清标记（见 lib-install-hooks.sh）。

set -o errexit
set -o pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_LIB_DIR}/lib-install-hooks.sh"
source "${_LIB_DIR}/adapters/opencode.sh"

# 子命令白名单：必须在取锁前校验——拼错的子命令不应先白等最多 10s 锁超时
case "${1:-install}" in
    install|uninstall|check) ;;
    *)
        echo "Usage: $0 [install|uninstall|check [--json]]" >&2
        exit 2
        ;;
esac

# 写路径互斥（check 只读不锁）：见 _install_acquire_lock 头注释。
case "${1:-install}" in
    check) ;;
    *)
        _lock_rc=0
        _install_acquire_lock opencode || _lock_rc=$?
        if [ "$_lock_rc" = 1 ]; then exit 1; fi
        if [ "$_lock_rc" = 0 ]; then
            trap '_install_release_lock opencode' EXIT
        fi
        ;;
esac

case "${1:-install}" in
    uninstall)
        adapter_uninstall_hooks
        # 先清安装意图再写卸载意图（理由同 claude wrapper）
        _hooks_installed_clear opencode || true
        _hooks_suppress_write opencode
        ;;
    check)
        if [ "${2:-}" = "--json" ]; then
            _wrapper_check_json opencode
        elif adapter_check_integrity; then
            echo ok
        else
            echo missing
            exit 1
        fi
        ;;
    install)
        adapter_install_hooks
        _hooks_suppress_clear opencode || true
        _hooks_installed_ensure opencode || true
        ;;
    *)
        echo "Usage: $0 [install|uninstall|check [--json]]" >&2
        exit 2
        ;;
esac
