# 设计文档：ESC 键清除 `!`/`?` 状态

## Context

当前插件通过 Claude Code hook 事件追踪每个 pane 的状态。当状态变为 `!`（等待授权）或 `?`（等待用户输入）时，用户可能通过 ESC 键取消了操作，但状态栏不会立即更新（需要等 watcher 轮询或下一个 hook 事件）。

**目标**：当用户在有 `!`/`?` 状态的活跃 pane 中按下 ESC 键时，立即将状态重置为 `-`（空闲），提供更快的视觉反馈。

## 方案：动态 ESC 绑定

### 核心思路

- 仅当至少一个 pane 处于 `!` 或 `?` 状态时，才注册 `bind-key -n Escape`
- 当所有 `!`/`?` 状态都清除后，自动解除绑定
- 绑定触发时，检查当前活跃 pane 的状态：若为 `!`/`?` 则重置，否则通过 `send-keys Escape` 原样传递

### 影响范围

- **有 `!`/`?` 时**：所有 ESC 按键增加 ~50-100ms 延迟（`run-shell` 开销），包括 vim 等应用
- **无 `!`/`?` 时**：绑定不存在，零影响
- **用户在 `!`/`?` pane 按 ESC**：状态立即重置，不传递 ESC（用户意图是取消）
- **用户在其他 pane 按 ESC**：检查通过后 `send-keys Escape` 传递给应用

## 修改文件

### `scripts/tmux-claude-status`

#### 1. 添加脚本路径解析（第 8 行后）

```bash
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
```

#### 2. 添加 `_esc_clear` 早期处理（第 8 行后，在 `INPUT=$(cat)` 之前）

当从 ESC 绑定调用时，跳过 `INPUT=$(cat)` 和进程树遍历，直接处理：

```bash
# ESC 快速路径：跳过 stdin 读取和进程树遍历
if [ "$EVENT" = "_esc_clear" ]; then
    ESC_PANE="$2"
    _cur=$(tmux display-message -pt "$ESC_PANE" -p "#{@claude_pane_status}" 2>/dev/null)
    if [ "$_cur" = "!" ] || [ "$_cur" = "?" ]; then
        TMUX_PANE="$ESC_PANE"
        WATCHER_PID_FILE="/tmp/claude-watcher-${TMUX_PANE//[^a-zA-Z0-9]/_}.pid"
        PROTECT_FILE="/tmp/claude-protect-${TMUX_PANE//[^a-zA-Z0-9]/_}"
        kill_watcher
        tmux set-option -pt "$TMUX_PANE" @claude_pane_status "-" 2>/dev/null
        build_all_status
        tmux set-option -g @claude_all_status "$ALL" 2>/dev/null || true
        tmux refresh-client -S 2>/dev/null || true
        _maybe_unbind_esc
    else
        # 非 !/? 状态，原样传递 ESC
        tmux send-keys -t "$ESC_PANE" Escape
    fi
    exit 0
fi
```

#### 3. 添加 ESC 绑定/解绑辅助函数（在 `kill_watcher()` 后，约第 93 行）

```bash
# 绑定 ESC 键到 _esc_clear 处理器
_bind_esc() {
    # 如果已有绑定（可能是我们自己的），跳过
    tmux list-keys -n 2>/dev/null | grep -q "bind-key.*-n.*Escape.*_esc_clear" && return
    tmux bind-key -n Escape run-shell "'$SCRIPT_PATH' _esc_clear '#{pane_id}'" 2>/dev/null || true
}

# 检查是否还有任何 pane 处于 !/? 状态，若没有则解绑 ESC
_maybe_unbind_esc() {
    if ! tmux list-panes -a -F "#{@claude_pane_status}" 2>/dev/null | grep -qE "^[!?]$"; then
        tmux unbind-key -n Escape 2>/dev/null || true
    fi
}
```

#### 4. 在设置 `!`/`?` 状态后调用 `_bind_esc`（3 处）

**第 185-186 行**（Notification permission）:
```bash
start_status_watcher "!"
_bind_esc   # ← 新增
```

**第 194-196 行**（PermissionRequest）:
```bash
start_status_watcher "!"
_set_protection
_bind_esc   # ← 新增
```

**第 202-204 行**（PreToolUse AskUserQuestion）:
```bash
start_status_watcher "?"
_set_protection
_bind_esc   # ← 新增
```

#### 5. 在 watcher 内重置状态后调用 `_maybe_unbind_esc`（2 处）

watcher 运行在子 shell `(...)` 中，但子 shell 会继承父 shell 的函数定义，因此可以直接调用。

**第 143 行后**（watcher 进程退出检测后）和 **第 159 行后**（pane title 变化检测后）:
```bash
_maybe_unbind_esc   # ← 新增
```

#### 6. 在主 case 中已有状态重置处添加 `_maybe_unbind_esc`（4 处）

- **第 180 行**（Notification denied/cancelled 后，`kill_watcher` 之后）
- **第 223 行**（PostToolUse/PostToolUseFailure 后，`kill_watcher` 之后）
- **第 227 行**（UserPromptSubmit 后，`kill_watcher` 之后）
- **第 235 行**（Stop/StopFailure 中 `!`/`?` 重置后）

每处在 `kill_watcher` 之后添加：
```bash
_maybe_unbind_esc   # ← 新增
```

## 验证方式

```bash
# 1. 触发 PermissionRequest 模拟
echo '{}' | bash scripts/tmux-claude-status PermissionRequest
# 检查绑定已注册
tmux list-keys -n | grep Escape

# 2. 在该 pane 中按 ESC
# 预期：状态立即变为 -

# 3. 检查绑定已清理
tmux list-keys -n | grep Escape
# 预期：无输出（绑定已解除）

# 4. 在其他 pane（非 !/?）按 ESC
# 预期：ESC 正常传递给应用程序，状态不变

# 5. 在 vim 中测试 ESC 延迟
# 前提：另一个 pane 有 ! 状态
# 按 ESC 退出 insert mode
# 预期：稍有延迟（~50-100ms）但仍正常工作

# 6. 测试无 !/? 状态时 ESC 无延迟
# 前提：所有 pane 都是 - 或 > 状态
# 在 vim 中按 ESC
# 预期：正常响应，无额外延迟
```
