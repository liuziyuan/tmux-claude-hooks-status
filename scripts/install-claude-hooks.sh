#!/bin/bash
# install-claude-hooks.sh — Claude Code hooks 安装/卸载/检查 wrapper
# 用法: install-claude-hooks.sh [install|uninstall|check [--json]|auto]
#
# 薄 wrapper：source 公共骨架 + claude adapter，dispatch 到 adapter_install_hooks /
# adapter_uninstall_hooks。实际逻辑在 scripts/adapters/claude.sh。
# check：输出 ok/missing（exit 0/1），供 TUI 侦测在 cc-switch 模式下走 bash 侧
# 完整性判定（sqlite 真源），与非 cc-switch 的文件判定共用同一真相。
# check --json：单行紧凑明细 JSON（mode/events/plugin/registeredPaths/suppress/drift），
# 同样 exit 0/1，供 tmuxclihook check 子命令与 TUI 渲染（见 lib-install-hooks.sh）。
# auto：tmux 入口加载时的自动安装——存在卸载意图标记（suppressed-claude）时不装。
# 显式 uninstall 成功写标记、显式 install 成功清标记（见 lib-install-hooks.sh）。

set -o errexit
set -o pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_LIB_DIR}/lib-install-hooks.sh"
source "${_LIB_DIR}/adapters/claude.sh"

# 写路径互斥（check 只读不锁）：临界区覆盖 adapter 调用 + suppress 标记读-改-写，
# 串行化 auto 与显式 uninstall 的标记 TOCTOU。失败语义见 _install_acquire_lock：
# 降级无锁（rc=2）继续；等待超时（rc=1）退出。
case "${1:-install}" in
    check) ;;
    *)
        _lock_rc=0
        _install_acquire_lock claude || _lock_rc=$?
        if [ "$_lock_rc" = 1 ]; then exit 1; fi
        if [ "$_lock_rc" = 0 ]; then
            trap '_install_release_lock claude' EXIT
        fi
        ;;
esac

case "${1:-install}" in
    uninstall)
        adapter_uninstall_hooks
        _hooks_suppress_write claude
        ;;
    check)
        if [ "${2:-}" = "--json" ]; then
            _wrapper_check_json claude
        elif adapter_check_integrity; then
            echo ok
        else
            echo missing
            exit 1
        fi
        ;;
    auto)
        if [ -f "$(_hooks_suppress_file claude)" ]; then
            exit 0
        fi
        # 已收敛（integrity + 无漂移/死条目/重复）→ 跳过重装：tmux 每次 reload
        # 不再全量重写真源。强收敛保留——漂移/死条目/缺失/重复任一存在都走
        # install 收敛。结构漂移（async/matcher 被外部改）不在判定内，auto 跳过
        # 不修复，显式 install 仍强收敛。
        if adapter_check_converged; then
            echo "claude hooks already converged (skip install)"
            exit 0
        fi
        adapter_install_hooks
        _hooks_suppress_clear claude || true
        ;;
    *)
        adapter_install_hooks
        _hooks_suppress_clear claude || true
        ;;
esac
