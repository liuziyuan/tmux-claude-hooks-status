#!/bin/bash
# install-opencode-hooks.sh — opencode plugin 安装/卸载 wrapper
# 用法: install-opencode-hooks.sh [uninstall]
#
# 薄 wrapper：source 公共骨架 + opencode adapter，dispatch 到 adapter_install_hooks /
# adapter_uninstall_hooks。实际逻辑在 scripts/adapters/opencode.sh。

set -o errexit
set -o pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_LIB_DIR}/lib-install-hooks.sh"
source "${_LIB_DIR}/adapters/opencode.sh"

if [ "${1:-install}" = "uninstall" ]; then
    adapter_uninstall_hooks
else
    adapter_install_hooks
fi
