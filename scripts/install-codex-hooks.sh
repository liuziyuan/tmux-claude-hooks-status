#!/bin/bash
# install-codex-hooks.sh — Codex CLI hooks 安装/卸载 wrapper（需 codex ≥ 0.144）
# 用法: install-codex-hooks.sh [uninstall]
#
# 薄 wrapper：source 公共骨架 + codex adapter，dispatch 到 adapter_install_hooks /
# adapter_uninstall_hooks。实际逻辑在 scripts/adapters/codex.sh。

set -o errexit
set -o pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_LIB_DIR}/lib-install-hooks.sh"
source "${_LIB_DIR}/adapters/codex.sh"

if [ "${1:-install}" = "uninstall" ]; then
    adapter_uninstall_hooks
else
    adapter_install_hooks
fi
