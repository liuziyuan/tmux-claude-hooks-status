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
#   adapter_check_detail()    check --json 明细 JSON 片段（可选实现；仅 install wrapper
#                             的 check --json 上下文调用，失败输出降级片段不报错）
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
                        | select(.command | contains("tmux-ai-status") | not)
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
                    .[] | .hooks = [.hooks[] | select(.command | contains("tmux-ai-status") | not)]
                    | select(.hooks | length > 0)
                ]
                | select(.value | length > 0)
            ] | from_entries
        else . end
'

_claude_apply_merge() {  # $1=输入 JSON 文件 → stdout 变换后全文档
    jq --arg tool_cmd "${_LIB_DIR}/tmux-ai-status claude" \
       "$_CLAUDE_JQ_MERGE" "$1"
}

_claude_apply_strip() {  # $1=输入 JSON 文件 → stdout 变换后全文档
    jq "$_CLAUDE_JQ_STRIP" "$1"
}

_claude_count_registered() {  # $1=输入 JSON 文件 → stdout 事件数（jq 失败时为空）
    jq "$_CLAUDE_JQ_COUNT" "$1" 2>/dev/null
}

# ─── cc-switch 通用配置支持 ───
# `switch` 命令启动 claude 时把「共享配置」深合并进实例 settings.json
# （provider meta 均 commonConfigEnabled=true）。~/.claude/settings.json 与实例
# 文件都会被 cc-switch 覆盖，共享配置才是 hooks 的唯一持久真源。
#
# 共享配置的真源位置随 cc-switch 版本变化（规则与 cc-switch CLI 的
# detectSharedConfigMode 保持一致）：
#   - legacy（< 4.0.2 / db PRAGMA user_version < 20）：
#       真源 = db settings 表的 common_config_claude（JSON）
#   - live（4.0.2+ / user_version >= 20）：
#       真源 = ~/.claude/settings.json —— 4.0.2 起 cc-switch 不再读库里的
#       common_config_claude（仅作迁移快照），所以新机器上写库等于写进死信。
#   - CC_SWITCH_SHARED_SOURCE=live|legacy 可显式覆盖（cc-switch 同款逃生阀）
# 门禁不过（db/表/sqlite3 缺失）→ none，整体回退传统文件模式。

_ccswitch_db() { printf '%s\n' "${HOME}/.cc-switch/cc-switch.db"; }

# live 模式真源：cc-switch 硬编码 $HOME/.claude/settings.json，
# 不随 CLAUDE_CONFIG_DIR 变化（后者指向的是 switch 实例目录）。
_ccswitch_live_file() { printf '%s\n' "${HOME}/.claude/settings.json"; }

# 输出 live|legacy|none；恒返回 0（调用方无需容忍失败分支）。
_ccswitch_mode() {
    local db override version
    db="$(_ccswitch_db)"
    if [ ! -f "$db" ] || ! command -v sqlite3 >/dev/null 2>&1; then
        printf 'none\n'
        return 0
    fi
    if ! sqlite3 -readonly "$db" \
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'" 2>/dev/null \
        | grep -q 1; then
        printf 'none\n'
        return 0
    fi
    override=$(printf '%s' "${CC_SWITCH_SHARED_SOURCE:-}" | tr '[:upper:]' '[:lower:]')
    case "$override" in
        live|legacy) printf '%s\n' "$override"; return 0 ;;
    esac
    # 读不到版本（空/非数字）按 legacy——与 cc-switch CLI 的 null → legacy 一致
    version=$(sqlite3 -readonly "$db" "PRAGMA user_version" 2>/dev/null | tr -cd '0-9')
    if [ -n "$version" ] && [ "$version" -ge 20 ]; then
        printf 'live\n'
    else
        printf 'legacy\n'
    fi
}

# cc-switch GUI 运行中会把内存缓存的共享配置全量写回真源（实测发生过），警告不阻塞。
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
# 三要素：10 事件计数 + 每个事件至少一条条目的脚本文件存活（test -x）。
# 计数齐但脚本死（npm 包卸载/volta 升级换路径，含部分事件死）→ missing → 自修复重装收敛。
# 存活提取内联在本函数（jq + test），不依赖 lib-install-hooks.sh——本函数同时被
# 事件路径（lib-tmux-ai-status.sh）与 install wrapper（lib-install-hooks.sh）两个上下文调用。
adapter_check_integrity() {
    local mode src="" tmp="" registered ev p ok_events=""
    mode=$(_ccswitch_mode)
    case "$mode" in
        live)
            src=$(_ccswitch_live_file)
            [ -f "$src" ] || return 1
            ;;
        legacy)
            _ccswitch_dump_common tmp || return 1
            src="$tmp"
            ;;
        *)
            [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
            src="$ADAPTER_HOOKS_FILE"
            ;;
    esac
    registered=$(_claude_count_registered "$src")
    if [ "${registered:-0}" -ge 10 ]; then
        while IFS=$'\t' read -r ev p; do
            if [ -n "$ev" ] && [ -x "$p" ]; then
                case ",$ok_events," in *",$ev,"*) ;; *) ok_events="$ok_events,$ev" ;; esac
            fi
        done < <(jq -r '.hooks as $h |
            ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
             "PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure"] as $events |
            $events[] as $e |
            [$h[$e][]?.hooks[]?.command // empty
             | select(contains("tmux-ai-status")) | split(" ")[0]] as $scripts |
            select(($scripts | length) > 0) |
            $scripts[] | "\($e)\t\(.)"' "$src" 2>/dev/null)
    fi
    [ -z "$tmp" ] || rm -f "$tmp"
    [ "${registered:-0}" -ge 10 ] || return 1
    for ev in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop StopFailure; do
        case ",$ok_events," in *",$ev,"*) ;; *) return 1 ;; esac
    done
    return 0
}

# 已收敛判定（仅供 wrapper 的 auto 分支使用——⚠️ 不得被事件路径复用）。
# 四条件全过 = auto 可安全跳过重装：integrity 过 + 全部条目指向当前源（无漂移/
# 死条目）+ 每事件本插件条目 ≤1（无重复）。
# 参照系：wrapper 的 _LIB_DIR 是 pwd -P 物理路径；写入（install/auto/修复全部经
# wrapper）与比较同参照系自洽。事件路径的 _LIB_DIR 是 pwd 逻辑路径（软链场景
# 两者不等），事件路径复用会误判漂移。
# 取源逻辑与 adapter_check_integrity 的三模式 case 保持同步（不抽共享以控制
# integrity 的回归面）。
adapter_check_converged() {
    adapter_check_integrity || return 1
    local mode src="" tmp="" stats
    mode=$(_ccswitch_mode)
    case "$mode" in
        live)
            src=$(_ccswitch_live_file)
            [ -f "$src" ] || return 1
            ;;
        legacy)
            _ccswitch_dump_common tmp || return 1
            src="$tmp"
            ;;
        *)
            [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
            src="$ADAPTER_HOOKS_FILE"
            ;;
    esac
    # 一次 jq 同时产出漂移计数（≠ 当前源，含死路径）与重复计数（每事件条目 >1）
    stats=$(jq -r --arg cur "${_LIB_DIR}/tmux-ai-status" '
        .hooks as $h |
        ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
         "PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure"] as $events |
        [$events[] as $e |
            [$h[$e][]?.hooks[]?.command // empty
             | select(contains("tmux-ai-status")) | split(" ")[0]] as $scripts |
            select(($scripts | length) > 0) |
            {bad: ([$scripts[] | select(. != $cur)] | length),
             n: ($scripts | length)}]
        | "bad=\([.[].bad] | add // 0) dup=\([.[].n | select(. > 1)] | length)"' "$src" 2>/dev/null)
    [ -z "$tmp" ] || rm -f "$tmp"
    case "$stats" in
        "bad=0 dup=0") return 0 ;;
        *) return 1 ;;
    esac
}

# 明细检查（仅 install wrapper 的 check --json 调用；事件热路径不触达）。
# stdout 输出单行紧凑 JSON 片段 {"mode":...,"events":{...},"plugin":null,"registeredPaths":[...]}，
# 由 lib-install-hooks.sh 的 _wrapper_check_json 拼装 tool/status/suppress/drift。
# 数据源与存活口径（逐条 command test -x）与 adapter_check_integrity 完全一致；
# status 判定仍由 integrity 本体独立给出，两者永不发散。
# 任何失败（jq 失败/配置缺失）输出空 events 的降级片段，不 exit 非 0。
adapter_check_detail() {
    local source_mode src="" tmp="" pairs rows line ev p a
    source_mode=$(_ccswitch_mode)
    case "$source_mode" in
        live)
            src=$(_ccswitch_live_file)
            [ -f "$src" ] || src=""
            ;;
        legacy)
            if ! _ccswitch_dump_common tmp; then
                printf '{"mode":"ccswitch","events":{},"plugin":null,"registeredPaths":[]}\n'
                return 0
            fi
            src="$tmp"
            ;;
        *)
            if [ -f "$ADAPTER_HOOKS_FILE" ]; then src="$ADAPTER_HOOKS_FILE"; fi
            ;;
    esac
    if [ -z "$src" ]; then
        case "$source_mode" in
            live) source_mode="ccswitch-live" ;;
            legacy) source_mode="ccswitch" ;;
            *) source_mode="file" ;;
        esac
        printf '{"mode":"%s","events":{},"plugin":null,"registeredPaths":[]}\n' "$source_mode"
        return 0
    fi
    case "$source_mode" in
        live) source_mode="ccswitch-live" ;;
        legacy) source_mode="ccswitch" ;;
        *) source_mode="file" ;;
    esac
    # TSV：event\tscript（不去重、保留零事件——计数与去重交给下游 jq 聚合）
    pairs=$(jq -r '.hooks as $h |
        ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
         "PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure"] as $events |
        $events[] as $e |
        $h[$e][]?.hooks[]?.command // empty |
        select(contains("tmux-ai-status")) | split(" ")[0] | "\($e)\t\(.)"' "$src" 2>/dev/null)
    [ -z "$tmp" ] || rm -f "$tmp"
    # TSV：event\tscript\talive(0|1)。bash 3.2 无关联数组，逐行展开后由 jq 一次聚合。
    rows=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        ev="${line%%$'\t'*}"
        p="${line#*$'\t'}"
        if [ -x "$p" ]; then a=1; else a=0; fi
        rows="${rows}${ev}"$'\t'"${p}"$'\t'"${a}"$'\n'
    done <<EOF
$pairs
EOF
    jq -R -s --arg mode "$source_mode" --arg events "$_CLAUDE_EVENTS" '
        (reduce ($events | split(" ")[]) as $e
            ({}; .[$e] = {registered: 0, alive: 0, scriptPaths: []})) as $base
        | reduce (split("\n") | .[] | select(length > 0) | split("\t")) as $r (
            $base;
            .[$r[0]] = {
                registered: (.[$r[0]].registered + 1),
                alive: (.[$r[0]].alive + ($r[2] | tonumber)),
                scriptPaths: ((.[$r[0]].scriptPaths + [$r[1]]) | unique)
            })
        | {mode: $mode, events: ., plugin: null,
           registeredPaths: ([.[] | .scriptPaths[]] | unique)}
    ' <<<"$rows"
}

# 安装：合并式更新，保留他人（masko 等）注册的 hook。
# legacy 模式只写库（~/.claude/settings.json 与实例文件都会被旧版 cc-switch 覆盖）；
# live 模式（4.0.2+）写 ~/.claude/settings.json —— 新版 cc-switch 以它为共享真源，
# 实例 settings 在 switch/漂移收敛时从该文件重新派生。
adapter_install_hooks() {
    _install_require_jq
    local mode target updated
    mode=$(_ccswitch_mode)
    case "$mode" in
        legacy)
            local tmp merged hooks_patch full_doc
            _ccswitch_warn_gui
            _ccswitch_dump_common tmp || return 1
            merged=$(_claude_apply_merge "$tmp")
            # 语义不变跳写：merge 只动 .hooks，顶层其他字段天然继承 tmp——
            # 两边 jq -S 规范化对比，相同则跳过 upsert（GUI 冲掉 hooks 时
            # 库内现值 ≠ merged，恒不跳，对抗不弱化；行缺失时 tmp={}，
            # merged 恒含 10 事件，同样恒不跳）
            if [ "$(jq -S . "$tmp" 2>/dev/null)" = "$(jq -S . <<<"$merged" 2>/dev/null)" ]; then
                rm -f "$tmp"
                echo "Claude hooks already up to date in cc-switch common config (skip write)"
                echo "Events: $_CLAUDE_EVENTS"
                return 0
            fi
            rm -f "$tmp"
            hooks_patch=$(jq -c '{hooks: (.hooks // {})}' <<<"$merged")
            full_doc=$(jq -c . <<<"$merged")
            _ccswitch_upsert_hooks "$hooks_patch" "$full_doc" || return 1
            echo "Claude hooks installed to cc-switch common config (legacy): $(_ccswitch_db)"
            echo "Events: $_CLAUDE_EVENTS"
            return 0
            ;;
        live)
            _ccswitch_warn_gui
            target=$(_ccswitch_live_file)
            ;;
        *)
            target="$ADAPTER_HOOKS_FILE"
            ;;
    esac
    [ -f "$target" ] || _install_atomic_write '{}' "$target"
    updated=$(_claude_apply_merge "$target")
    # 语义不变跳写：jq 输出格式与手写文件不同，字节 cmp 不可用——两边 jq -S
    # 规范化后比较（命令替换对称剥尾换行）。跳写不触碰 mtime，避免触发 Claude
    # Code file watcher 的无谓 hooks 重载。
    if [ "$(jq -S . "$target" 2>/dev/null)" = "$(jq -S . <<<"$updated" 2>/dev/null)" ]; then
        echo "Claude hooks already up to date at $target (skip write)"
        echo "Events: $_CLAUDE_EVENTS"
        return 0
    fi
    _install_atomic_write "$updated" "$target"
    echo "Claude hooks installed to $target"
    echo "Events: $_CLAUDE_EVENTS"
}

# 卸载：单次 jq pipeline 移除所有指向本插件的 hooks，保留他人条目。
# legacy 模式：剥离前后对照生成 patch（被清空的事件键置 null = RFC 7396 删键），
# 顶层其他字段（model/env/…）由 json_patch 天然保留。
# live 模式：与文件模式同一套原子写（真源就是 ~/.claude/settings.json）。
adapter_uninstall_hooks() {
    _install_require_jq
    local mode target updated
    mode=$(_ccswitch_mode)
    case "$mode" in
        legacy)
            local tmp stripped cur_hooks final_hooks patch managed top_patch
            _ccswitch_warn_gui
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
            top_patch=$(jq -cn --argjson p "$patch" '{hooks: $p}')
            _ccswitch_upsert_hooks "$top_patch" "$top_patch" || return 1
            echo "Claude hooks uninstalled from cc-switch common config (legacy)"
            return 0
            ;;
        live)
            _ccswitch_warn_gui
            target=$(_ccswitch_live_file)
            ;;
        *)
            target="$ADAPTER_HOOKS_FILE"
            ;;
    esac
    [ -f "$target" ] || { echo "Claude hooks: nothing to uninstall"; return 0; }
    updated=$(_claude_apply_strip "$target")
    # 无本插件条目时 strip 无变化 → 跳写（不触碰 mtime）
    if [ "$(jq -S . "$target" 2>/dev/null)" = "$(jq -S . <<<"$updated" 2>/dev/null)" ]; then
        echo "Claude hooks: nothing to uninstall from $target (skip write)"
        return 0
    fi
    _install_atomic_write "$updated" "$target"
    echo "Claude hooks uninstalled from $target"
}
