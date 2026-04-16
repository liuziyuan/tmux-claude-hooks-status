# 竞态机制改进方案

## 背景

当前竞态保护机制存在的问题：
- 时间窗口硬编码（3秒），延迟超过3秒会失效
- Watcher 轮询（每秒）浪费资源，响应延迟最多1秒
- 双重保护（事件端 + Watcher端）逻辑分散
- 临时文件管理（protect + PID）增加故障点

用户需求：
- 阻塞状态（!/?）需要加上**进程退出检测**作为解除条件

---

## 方案一：状态优先级系统

### 核心思想

定义状态优先级：**! > ? > > > -**

- `!` 和 `?` 是「阻塞状态」，优先级最高
- 只有阻塞事件（PermissionRequest/AskUserQuestion）可以设置阻塞状态
- 普通事件（PostToolUse 等）无法覆盖阻塞状态
- 解除条件：明确解除事件 **或** 进程退出检测

### 实现计划

#### 1. 新增状态优先级判断函数（lib-tmux-ai-status.sh）

```bash
# 判断是否允许设置新状态
# 参数: $1=当前状态, $2=要设置的状态, $3=事件类型
_can_set_status() {
    local current="$1"
    local new="$2"
    local event="$3"

    # 阻塞状态定义
    local blocking_states="! ?"

    # 如果当前是阻塞状态
    if [[ "$blocking_states" == *"$current"* ]]; then
        # 只有明确的解除事件才能覆盖
        case "$event" in
            Notification|Stop|StopFailure|SessionEnd)
                return 0
                ;;
            *)
                return 1  # 拒绝覆盖
                ;;
        esac
    fi

    return 0  # 非阻塞状态可以正常覆盖
}
```

#### 2. 修改事件处理逻辑（tmux-claude-status）

**PermissionRequest / PreToolUse(AskUserQuestion)**:
```bash
# 设置阻塞状态前无需检查，直接设置
case "$EVENT" in
    PermissionRequest)
        STATUS="!"
        # 启动 watcher（只做进程退出检测，不做二次保护）
        start_status_watcher "$TOOL_ID" "!"
        ;;
    PreToolUse)
        if [ "$TOOL" = "AskUserQuestion" ]; then
            STATUS="?"
            start_status_watcher "$TOOL_ID" "?"
        else
            # 检查优先级
            cur_status=$(tmux get-option -pt "$TMUX_PANE" @claude_pane_status 2>/dev/null)
            if ! _can_set_status "$cur_status" ">" "PostToolUse"; then
                exit 0  # 当前是阻塞状态，拒绝覆盖
            fi
            STATUS=">"
        fi
        ;;
esac
```

**PostToolUse**:
```bash
PostToolUse|PostToolUseFailure)
    cur_status=$(tmux get-option -pt "$TMUX_PANE" @claude_pane_status 2>/dev/null)
    if ! _can_set_status "$cur_status" ">" "PostToolUse"; then
        exit 0  # 阻塞状态保护
    fi
    STATUS=">"
    ;;
```

#### 3. 简化 Watcher（lib-tmux-ai-status.sh）

```bash
start_status_watcher() {
    local tool_id="$1"
    local protected_status="$2"
    # ... 只保留进程退出检测逻辑，移除时间戳保护和二次保护
    while true; do
        sleep 1
        # 检查进程是否退出
        if ! pgrep -P "$_pane_pid" >/dev/null 2>&1; then
            # 解除阻塞状态
            tmux set-option -pt "$TMUX_PANE" "$_pane_status_var" "-"
            # 重建聚合状态
            build_all_status
            tmux set-option -g @ai_all_status "$ALL"
            exit 0
        fi
    done
}
```

#### 4. 删除的代码

- `_set_protection()` 函数
- `_is_protected()` 函数
- `_clear_protection()` 函数
- Watcher 中的二次保护逻辑
- 事件端的所有 `_is_protected` 检查

### 优缺点

| 优点 | 缺点 |
|------|------|
| 逻辑清晰，易于理解 | 需要维护状态优先级规则 |
| 无时间依赖，不会因延迟失效 | 新增状态需要考虑优先级 |
| 代码简化，移除时间戳机制 | - |

---

## 方案二：工具调用ID追踪

### 核心思想

在 tmux 变量中记录「当前活跃工具ID」：
- PreToolUse 记录工具唯一标识（可用工具名 + 时间戳）
- PostToolUse 验证是否匹配当前工具ID
- 不匹配 = 过时工具的事件，忽略

阻塞状态（!/?）不记录工具ID，只能由明确事件解除。

### 实现计划

#### 1. 新增工具ID管理函数（lib-tmux-ai-status.sh）

```bash
# 生成工具调用ID
_generate_tool_id() {
    local tool_name="$1"
    local timestamp=$(date +%s%N)  # 纳秒级时间戳
    echo "${tool_name}:${timestamp}"
}

# 设置当前活跃工具ID
_set_active_tool() {
    local tool_id="$1"
    tmux set-option -pt "$TMUX_PANE" "@${TOOL_ID}_active_tool" "$tool_id"
}

# 检查工具ID是否匹配当前活跃工具
_is_active_tool() {
    local tool_id="$1"
    local current
    current=$(tmux display-message -pt "$TMUX_PANE" -p "#{@${TOOL_ID}_active_tool}" 2>/dev/null)
    [ "$current" = "$tool_id" ]
}

# 清除活跃工具ID
_clear_active_tool() {
    tmux set-option -pt "$TMUX_PANE" "@${TOOL_ID}_active_tool" ""
}
```

#### 2. 修改事件处理逻辑（tmux-claude-status）

**PreToolUse**:
```bash
PreToolUse)
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')
    # 检查当前是否阻塞状态
    cur_status=$(tmux get-option -pt "$TMUX_PANE" @claude_pane_status 2>/dev/null)
    if [ "$cur_status" = "!" ] || [ "$cur_status" = "?" ]; then
        exit 0  # 阻塞状态保护
    fi

    if [ "$TOOL" = "AskUserQuestion" ]; then
        STATUS="?"
        _clear_active_tool  # 阻塞状态不记录工具ID
        start_status_watcher "$TOOL_ID" "?"
    else
        # 生成并记录工具ID
        TOOL_ID=$(_generate_tool_id "$TOOL")
        _set_active_tool "$TOOL_ID"
        STATUS=">"
    fi
    ;;
```

**PostToolUse**:
```bash
PostToolUse|PostToolUseFailure)
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')
    # 重新生成工具ID进行验证
    EXPECTED_TOOL_ID=$(_generate_tool_id "$TOOL")
    if ! _is_active_tool "$EXPECTED_TOOL_ID"; then
        exit 0  # 不是当前活跃工具，忽略
    fi

    # 检查是否被阻塞状态覆盖
    cur_status=$(tmux get-option -pt "$TMUX_PANE" @claude_pane_status 2>/dev/null)
    if [ "$cur_status" = "!" ] || [ "$cur_status" = "?" ]; then
        _clear_active_tool
        exit 0  # 阻塞状态保护
    fi

    STATUS=">"
    _clear_active_tool
    ;;
```

**PermissionRequest**:
```bash
PermissionRequest)
    STATUS="!"
    _clear_active_tool  # 清除工具ID，进入阻塞状态
    start_status_watcher "$TOOL_ID" "!"
    ;;
```

#### 3. 简化 Watcher

同方案一，只保留进程退出检测。

#### 4. 新增 tmux 变量

- `@claude_active_tool` / `@copilot_active_tool`：存储当前活跃工具ID

### 优缺点

| 优点 | 缺点 |
|------|------|
| 精确匹配，无时间窗口限制 | 依赖纳秒级时间戳，可能有并发问题 |
| 逻辑清晰：工具调用配对 | 需要额外 tmux 变量 |
| 不需要保护窗口 | 工具ID生成需要考虑边界情况 |

---

## 方案三：简化当前方案

### 核心思想

保留时间戳机制，但简化实现：
- 移除 Watcher 的二次保护和轮询
- 只保留事件端的一次性检查
- 保留进程退出检测（简化版 watcher）

### 实现计划

#### 1. 保留竞态保护函数（lib-tmux-ai-status.sh）

```bash
# 时间戳保护机制（保持不变）
_set_protection() { ... }
_is_protected() { ... }
_clear_protection() { ... }
```

#### 2. 简化 Watcher（lib-tmux-ai-status.sh）

```bash
start_status_watcher() {
    local tool_id="$1"
    local protected_status="$2"
    # ... 只做进程退出检测，移除所有二次保护逻辑
    (
        # ... setup
        while true; do
            sleep 1
            _is_current || exit 0

            # 移除：二次保护逻辑（157-163行）

            # 只保留状态检查和进程退出检测
            [ "$cur_status" = "$_protected" ] || { _clear_protection "$_tool_id"; exit 0; }

            if [ "$_protected" = "!" ] && ! pgrep -P "$_pane_pid" >/dev/null 2>&1; then
                _is_current || exit 0
                tmux set-option -pt "$TMUX_PANE" "$_pane_status_var" "-"
                _clear_protection "$_tool_id"
                # ... refresh
                exit 0
            fi
        done
    ) &
}
```

#### 3. 事件端保持不变

事件端的所有 `_is_protected` 检查保持不变。

### 优缺点

| 优点 | 缺点 |
|------|------|
| 改动最小，风险低 | 仍依赖时间窗口 |
| 移除复杂的二次保护 | 延迟超过3秒仍会失效 |
| Watcher 逻辑简化 | - |

---

## 方案四：状态栈模式

### 核心思想

维护状态栈而非单个状态：
- PreToolUse: push 状态到栈
- PostToolUse: pop 状态
- 阻塞状态（!/?）：覆盖整个栈，设置阻塞标志

### 实现计划

#### 1. 新增状态栈管理（lib-tmux-ai-status.sh）

```bash
# 推入状态栈
_push_status() {
    local new_status="$1"
    tmux set-option -pt "$TMUX_PANE" "@${TOOL_ID}_status_stack" "${new_status}"
    tmux set-option -pt "$TMUX_PANE" "@${TOOL_ID}_status_depth" 1
}

# 弹出状态栈
_pop_status() {
    local depth
    depth=$(tmux display-message -pt "$TMUX_PANE" -p "#{@${TOOL_ID}_status_depth}" 2>/dev/null)
    depth=${depth:-0}
    if [ "$depth" -gt 0 ]; then
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then
            tmux set-option -pt "$TMUX_PANE" "@${TOOL_ID}_status_depth" 0
            echo "-"
        else
            # 从栈中恢复上一个状态（需要实现完整的栈存储）
            echo ">"
        fi
    else
        echo "-"
    fi
}

# 设置阻塞状态
_set_blocking_status() {
    local status="$1"
    tmux set-option -pt "$TMUX_PANE" "@${TOOL_ID}_blocking" "$status"
    tmux set-option -pt "$TMUX_PANE" "@${TOOL_ID}_status_depth" 0  # 清空栈
}

# 检查是否阻塞状态
_is_blocking() {
    local blocking
    blocking=$(tmux display-message -pt "$TMUX_PANE" -p "#{@${TOOL_ID}_blocking}" 2>/dev/null)
    [ -n "$blocking" ]
}
```

#### 2. 修改事件处理逻辑

**PreToolUse**:
```bash
PreToolUse)
    if _is_blocking; then
        exit 0  # 阻塞状态，忽略
    fi

    TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')
    if [ "$TOOL" = "AskUserQuestion" ]; then
        _set_blocking_status "?"
        start_status_watcher "$TOOL_ID" "?"
    else
        _push_status ">"
    fi
    ;;
```

**PostToolUse**:
```bash
PostToolUse|PostToolUseFailure)
    if _is_blocking; then
        exit 0
    fi

    STATUS=$(_pop_status)
    ;;
```

**PermissionRequest**:
```bash
PermissionRequest)
    _set_blocking_status "!"
    start_status_watcher "$TOOL_ID" "!"
    ;;
```

#### 3. 新增 tmux 变量

- `@claude_status_stack` / `@copilot_status_stack`：状态栈
- `@claude_status_depth` / `@copilot_status_depth`：栈深度
- `@claude_blocking` / `@copilot_blocking`：阻塞状态标志

### 优缺点

| 优点 | 缺点 |
|------|------|
| 自然处理嵌套调用 | 需要实现完整的栈结构 |
| 状态转换清晰 | tmux 变量存储栈有限制 |
| 适合复杂场景 | 对于简单场景过度设计 |

---

## 推荐方案

综合考虑，**方案一（状态优先级系统）**是最推荐的选择：

1. **简洁性**：逻辑清晰，易于理解和维护
2. **可靠性**：无时间依赖，不会因延迟失效
3. **扩展性**：新增状态只需定义优先级
4. **用户体验**：阻塞状态不会被意外覆盖

---

## 关键文件

需要修改的文件：
- `scripts/lib-tmux-ai-status.sh` — 共享库
- `scripts/tmux-claude-status` — Claude 事件处理
- `scripts/tmux-copilot-status` — Copilot 事件处理

---

## 验证计划

1. **单元测试**：手动触发各种事件序列
2. **竞态测试**：模拟延迟的 PostToolUse 到达
3. **进程退出测试**：验证 watcher 正确检测进程退出
4. **压力测试**：快速连续触发多个事件

### 测试命令

```bash
# 模拟权限请求场景
echo '{}' | bash scripts/tmux-claude-status PreToolUse  # Bash
echo '{"tool_name":"Bash"}' | bash scripts/tmux-claude-status PostToolUse
echo '{}' | bash scripts/tmux-claude-status PermissionRequest  # 延迟的 PostToolUse 应被拦截
echo '{"tool_name":"Bash"}' | bash scripts/tmux-claude-status PostToolUse

# 验证状态
tmux display-message -pt "$TMUX_PANE" -p "#{@claude_pane_status}"
```
