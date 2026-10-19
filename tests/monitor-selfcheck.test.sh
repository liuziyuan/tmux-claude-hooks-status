#!/bin/bash
# tests/monitor-selfcheck.test.sh — monitor 内容指纹自检（升级后 exec 重载的依据）
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

DIR="$TEST_TMP/scripts"
mkdir -p "$DIR/adapters"
cp "$ROOT/scripts/tmux-ai-monitor" "$DIR/"
cp "$ROOT/scripts/lib-tmux-ai-status.sh" "$DIR/"
cp "$ROOT/scripts"/adapters/*.sh "$DIR/adapters/"

fingerprint() {
    ( cd "$DIR" && cat tmux-ai-monitor lib-tmux-ai-status.sh adapters/*.sh | cksum )
}

FP=$(fingerprint)
[ -n "$FP" ] || { echo "FAIL: 指纹为空" >&2; exit 1; }

# 未变化 → selfcheck exit 1
if bash "$DIR/tmux-ai-monitor" selfcheck "$FP"; then
    echo "FAIL: 未变化时 selfcheck 应返回 1" >&2; exit 1
fi

# 修改任一脚本内容（不依赖 mtime，符合 npm 保留旧 mtime 的场景）→ exit 0
printf '\n# changed\n' >> "$DIR/lib-tmux-ai-status.sh"
if ! bash "$DIR/tmux-ai-monitor" selfcheck "$FP"; then
    echo "FAIL: 内容变化后 selfcheck 应返回 0" >&2; exit 1
fi

# 新指纹自检 → 再次返回 1（不会 exec 风暴）
FP2=$(fingerprint)
if bash "$DIR/tmux-ai-monitor" selfcheck "$FP2"; then
    echo "FAIL: 新指纹下 selfcheck 应返回 1" >&2; exit 1
fi

# 空指纹 → exit 1
if bash "$DIR/tmux-ai-monitor" selfcheck ""; then
    echo "FAIL: 空指纹应返回 1" >&2; exit 1
fi

echo "PASS: monitor selfcheck 用例全部通过"
