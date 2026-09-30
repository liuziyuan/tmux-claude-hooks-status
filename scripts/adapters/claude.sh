#!/bin/bash
# adapters/claude.sh — Claude Code 工具适配器
#
# 由 lib-tmux-ai-status.sh 在确定 TOOL_ID=claude 后 source。声明 Claude Code 与其他
# AI CLI 的差异；核心引擎读本文件暴露的变量/函数分派，不再写 case "$TOOL_ID"。
#
# 契约（每个 adapter 必须定义）：
#   ADAPTER_EVENTS            该工具触发的事件集合（空格分隔）
#   ADAPTER_PROCESS_NAMES     进程名（basename）集合，供 _pane_has_ai_process 识别
#   ADAPTER_HOOKS_FILE        hooks 配置文件绝对路径
#   ADAPTER_HAS_SESSION_END   "true"|"false" 是否有 SessionEnd 事件
#   ADAPTER_SESSION_START_TIMING  "immediate"|"deferred" SessionStart 时机
#   ADAPTER_HOLD_UNMATCHED_PERMISSION "true"|"false" 无请求 ID 时是否保守保持审批态
#   ADAPTER_INSTALLER         install 脚本绝对路径（供自修复/TUI 调用）
#   adapter_check_integrity() hooks 是否完整注册本插件（返回 0=完整）
#   adapter_install_hooks()   安装 hooks（合并式，保留他人 hook）
#   adapter_uninstall_hooks() 卸载本插件 hooks
#
# install/uninstall 依赖 lib-install-hooks.sh 的 _install_require_jq/_install_atomic_write，
# 仅在被 install wrapper source 时可用；事件路径 source 本文件只定义函数不调用，零开销。

# Claude Code 注册 10 个事件，全部 async（PermissionRequest 例外 sync）。
ADAPTER_EVENTS="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop StopFailure"

# 前台进程名（BFS pane 进程树匹配 basename）
ADAPTER_PROCESS_NAMES="claude"

# hooks 配置：~/.claude/settings.json（CLAUDE_CONFIG_DIR 可覆盖）。
# 仅在非 cc-switch 环境作为写入目标；cc-switch 环境见 _ccswitch_active。
ADAPTER_HOOKS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Claude Code 有 SessionEnd 事件，退出即发 hook → 状态可主动清。
ADAPTER_HAS_SESSION_END="true"
# SessionStart 在 CLI 启动时立即触发（对比 codex 延迟到首个 turn）。
ADAPTER_SESSION_START_TIMING="immediate"
# Claude 当前串行执行工具，完成事件可解除无 ID 的审批态。
ADAPTER_HOLD_UNMATCHED_PERMISSION="false"

# 自修复/TUI 调用的安装脚本
ADAPTER_INSTALLER="${_LIB_DIR}/install-claude-hooks.sh"

# Claude 事件集合（含同步事件 PermissionRequest）。install/uninstall 用。
_CLAUDE_EVENTS="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop StopFailure"

# ─── jq 程序常量：文件模式与 cc-switch 模式共用同一合并/剥离/计数核心 ───
# 程序文本内无单引号，可安全放入单引号 shell 变量。

# 完整性计数：10 个事件中注册了含 tmux-ai-status 的 command 的事件数。
_CLAUDE_JQ_COUNT='
    .hooks as $h |
    ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
     "PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure"]
    | map(select([$h[.][]?.hooks[]?.command // empty] | any(contains("tmux-ai-status"))))
    | length
'

# 合并式安装：剥 legacy 名（tmux-claude-status / tmux-powerline-claude-status）+
# 指向其他路径的 stale tmux-ai-status 条目，$tool_cmd 未注册则追加。
# PermissionRequest 为 sync（async=false）。
_CLAUDE_JQ_MERGE='
        ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
         "PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure"] as $events |
        ["PermissionRequest"] as $sync_events |
        reduce $events[] as $event (
            .;
            ($tool_cmd + " " + $event) as $hook_cmd |
            .hooks //= {} |
            .hooks[$event] //= [] |
            .hooks[$event] |= (
                map(
                    .hooks = [
                        .hooks[]
                        | select(.command | contains("tmux-powerline-claude-status") | not)
                        | select(.command | contains("tmux-claude-status") | not)
                        | select(
                            (.command | contains("tmux-ai-status") | not)
                            or (.command | startswith($dev_script))
                        )
                    ]
                    | select(.hooks | length > 0)
                )
            ) |
            if ([.hooks[$event][]?.hooks[]?.command] | index($hook_cmd)) == null then
                .hooks[$event] += [{
                    "hooks": [{
                        "async": (($event | IN($sync_events[])) | not),
                        "command": $hook_cmd,
                        "type": "command"
                    }],
                    "matcher": ""
                }]
            else . end
        )
'

# 剥离：移除所有指向本插件的条目，保留他人 hook，空 group/事件删除。
_CLAUDE_JQ_STRIP='
        .hooks |= if . then
            [. | to_entries[] |
                .value |= [
                    .[] | .hooks = [.hooks[] | select(.command | startswith($hook_script) | not)]
                    | select(.hooks | length > 0)
                ]
                | select(.value | length > 0)
            ] | from_entries
        else . end
'

_claude_apply_merge() {  # $1=输入 JSON 文件 → stdout 变换后全文档
    jq --arg dev_script "${_LIB_DIR}/tmux-ai-status" \
       --arg tool_cmd "${_LIB_DIR}/tmux-ai-status claude" \
       "$_CLAUDE_JQ_MERGE" "$1"
}

_claude_apply_strip() {  # $1=输入 JSON 文件 → stdout 变换后全文档
    jq --arg hook_script "${_LIB_DIR}/tmux-ai-status" "$_CLAUDE_JQ_STRIP" "$1"
}

_claude_count_registered() {  # $1=输入 JSON 文件 → stdout 事件数（jq 失败时为空）
    jq "$_CLAUDE_JQ_COUNT" "$1" 2>/dev/null
}

# ─── cc-switch 通用配置支持 ───
# `switch` 命令启动 claude 时把 ~/.cc-switch/cc-switch.db 的通用配置（settings 表
# common_config_claude，JSON）深合并进实例 settings.json（provider meta 均
# commonConfigEnabled=true）。~/.claude/settings.json 与实例文件都会被 cc-switch
# 覆盖，通用配置是 hooks 的唯一持久真源。检测到 cc-switch 时装/卸/完整性只操作
# 该库；sqlite3 缺失等一切门禁不过 → 整体回退传统文件模式。

_ccswitch_db() { printf '%s\n' "${HOME}/.cc-switch/cc-switch.db"; }

# 门禁：db 存在 && sqlite3 可用 && settings 表可查。不要求 key 存在
# （从未编辑过通用配置的用户由 install 的 upsert 建行；若此处要求 key，
# 会静默回退文件模式 → 实例永不含 hooks + 自修复空转）。
_ccswitch_active() {
    local db
    db="$(_ccswitch_db)"
    [ -f "$db" ] || return 1
    command -v sqlite3 >/dev/null 2>&1 || return 1
    sqlite3 -readonly "$db" \
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'" 2>/dev/null \
        | grep -q 1
}

# cc-switch GUI 运行中会把内存缓存的通用配置全量写回 db（实测发生过），警告不阻塞。
_ccswitch_warn_gui() {
    if pgrep -ix "cc-switch" >/dev/null 2>&1 \
       || pgrep -f "cc-switch.app/Contents/MacOS" >/dev/null 2>&1; then
        echo "WARN: cc-switch GUI 正在运行，其内存缓存可能在退出时覆盖本次写入；" \
             "建议退出 GUI 后重跑安装确认。tmux 会话活跃时自修复会在 60s 内重写。" >&2
    fi
}

# 读通用配置 value → mktemp 文件，路径写入 $1 命名的变量。
# 行缺失/空白 → "{}"；非空但非法 JSON → 明确报错 return 1（绝不覆盖用户数据）。
# 注意：内部临时变量名不得与调用方常用名（tmp 等）同名——bash 动态作用域下
# printf -v "$1" 会写到本函数的同名 local，函数返回即丢失。
_ccswitch_dump_common() {  # $1=out var name
    local _cc_out_file
    _cc_out_file=$(mktemp "${TMPDIR:-/tmp}/ccswitch-common.XXXXXX") || return 1
    sqlite3 -readonly "$(_ccswitch_db)" \
        "SELECT value FROM settings WHERE key='common_config_claude'" > "$_cc_out_file" 2>/dev/null
    if [ ! -s "$_cc_out_file" ] || [ -z "$(tr -d '[:space:]' < "$_cc_out_file")" ]; then
        printf '{}\n' > "$_cc_out_file"
    elif ! jq -e . "$_cc_out_file" >/dev/null 2>&1; then
        rm -f "$_cc_out_file"
        echo "ERROR: cc-switch 通用配置不是合法 JSON，拒绝操作。排查:" >&2
        echo "  sqlite3 -readonly $(_ccswitch_db) \"SELECT value FROM settings WHERE key='common_config_claude'\"" >&2
        return 1
    fi
    printf -v "$1" '%s' "$_cc_out_file"
}

# SQL 字符串字面量转义（' → ''），与 cc-launch 写回通用配置的 sqlQuote 同规则。
_sqlquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# 单条 upsert 写库：行存在 → json_patch 深合并（RFC 7396，只动 patch 内的键）；
# 行缺失 → 整文档插入。与 cc-launch 写回通用配置同款机制。
_ccswitch_upsert_hooks() {  # $1=hooks patch JSON(紧凑)  $2=完整文档 JSON(行缺失时插入用)
    local sql
    sql="INSERT INTO settings(key, value) VALUES('common_config_claude', json($(_sqlquote "$2")))
ON CONFLICT(key) DO UPDATE SET value = json_patch(settings.value, json($(_sqlquote "$1")))"
    if ! sqlite3 -cmd ".timeout 5000" "$(_ccswitch_db)" "$sql" 2>/dev/null; then
        echo "ERROR: 写入 cc-switch.db 失败（库可能被占用；tmux 会话活跃时自修复会重试）" >&2
        return 1
    fi
}

# 完整性检查：cc-switch 模式查通用配置；否则查 hooks 配置文件。
# 10 个事件都注册了本插件 hook 才算完整；缺失（外部覆盖）→ 返回 1 触发自修复。
adapter_check_integrity() {
    local registered tmp
    if _ccswitch_active; then
        _ccswitch_dump_common tmp || return 1
        registered=$(_claude_count_registered "$tmp")
        rm -f "$tmp"
    else
        [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
        registered=$(_claude_count_registered "$ADAPTER_HOOKS_FILE")
    fi
    [ "${registered:-0}" -ge 10 ]
}

# 安装：合并式更新，保留他人（masko 等）注册的 hook。cc-switch 模式只写库
# （~/.claude/settings.json 与实例文件都会被 cc-switch 覆盖，写了也不持久）。
adapter_install_hooks() {
    _install_require_jq
    if _ccswitch_active; then
        local tmp merged hooks_patch full_doc
        _ccswitch_warn_gui
        _ccswitch_dump_common tmp || return 1
        merged=$(_claude_apply_merge "$tmp")
        rm -f "$tmp"
        hooks_patch=$(jq -c '{hooks: (.hooks // {})}' <<<"$merged")
        full_doc=$(jq -c . <<<"$merged")
        _ccswitch_upsert_hooks "$hooks_patch" "$full_doc" || return 1
        echo "Claude hooks installed to cc-switch common config: $(_ccswitch_db)"
        echo "Events: $_CLAUDE_EVENTS"
        return 0
    fi
    [ -f "$ADAPTER_HOOKS_FILE" ] || _install_atomic_write '{}' "$ADAPTER_HOOKS_FILE"
    local updated
    updated=$(_claude_apply_merge "$ADAPTER_HOOKS_FILE")
    _install_atomic_write "$updated" "$ADAPTER_HOOKS_FILE"
    echo "Claude hooks installed to $ADAPTER_HOOKS_FILE"
    echo "Events: $_CLAUDE_EVENTS"
}

# 卸载：单次 jq pipeline 移除所有指向本插件的 hooks，保留他人条目。
# cc-switch 模式：剥离前后对照生成 patch（被清空的事件键置 null = RFC 7396 删键），
# 顶层其他字段（model/env/…）由 json_patch 天然保留。
adapter_uninstall_hooks() {
    _install_require_jq
    if _ccswitch_active; then
        local tmp stripped cur_hooks final_hooks patch managed top_patch
        _ccswitch_dump_common tmp || return 1
        cur_hooks=$(jq -c '.hooks // {}' "$tmp")
        # 已无本插件条目 → no-op（否则会把保留的他人 hook 重写一遍）
        managed=$(jq '[to_entries[] | select(.value | any(.hooks[]?.command | contains("tmux-ai-status")))] | length' <<<"$cur_hooks")
        if [ "${managed:-0}" -eq 0 ]; then
            rm -f "$tmp"
            echo "Claude hooks: nothing to uninstall (cc-switch common config)"
            return 0
        fi
        stripped=$(_claude_apply_strip "$tmp")
        final_hooks=$(jq -c '.hooks // {}' <<<"$stripped")
        rm -f "$tmp"
        patch=$(jq -cn --argjson cur "$cur_hooks" --argjson fin "$final_hooks" '
            reduce ($cur | keys[]) as $k ({};
                if ($fin | has($k)) then .[$k] = $fin[$k] else .[$k] = null end)')
        if [ "$patch" = "{}" ]; then
            echo "Claude hooks: nothing to uninstall (cc-switch common config)"
            return 0
        fi
        # patch 是事件级键，需包一层 {hooks: …} 才是顶层 patch（json_patch 只动 hooks）
        local top_patch
        top_patch=$(jq -cn --argjson p "$patch" '{hooks: $p}')
        _ccswitch_upsert_hooks "$top_patch" "$top_patch" || return 1
        echo "Claude hooks uninstalled from cc-switch common config"
        return 0
    fi
    [ -f "$ADAPTER_HOOKS_FILE" ] || { echo "Claude hooks: nothing to uninstall"; return 0; }
    local updated
    updated=$(_claude_apply_strip "$ADAPTER_HOOKS_FILE")
    _install_atomic_write "$updated" "$ADAPTER_HOOKS_FILE"
    echo "Claude hooks uninstalled from $ADAPTER_HOOKS_FILE"
}
