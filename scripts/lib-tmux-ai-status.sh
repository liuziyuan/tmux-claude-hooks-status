#!/bin/bash
# lib-tmux-ai-status.sh: 共享库 — TMUX_PANE 解析、状态聚合、pane title 监控
# 被 tmux-ai-status source
# 调用方需设置: TOOL_ID ("claude" | "codex" | "opencode")、SESSION_ID（从 hook input 解析）

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_STATUS_DIR="${TMUX_AI_STATUS_DIR:-/tmp/ai-status}"
# 卸载意图标记目录（suppressed-<tool>）。⚠️ 与 lib-install-hooks.sh 中的定义保持一致（两处同步改）。
_SUPPRESS_DIR="${TMUX_AI_SUPPRESS_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/tmuxclihook}"
STATUS_COLOR="#F1FA8C"

# 安装意图标记路径（与 lib-install-hooks.sh 的 _hooks_installed_file 同构）。
# 事件路径不 source 安装库，故此处独立实现；目录定义同 suppressed 两处同步。
# 语义：用户显式装过该工具 → 跨工具自修复允许在其 hooks 丢失时自动重装。
_installed_marker_path() { printf '%s/installed-%s' "$_SUPPRESS_DIR" "$1"; }
_installed_marker_write() {
    local f
    f=$(_installed_marker_path "$1") || return 1
    mkdir -p "$_SUPPRESS_DIR" 2>/dev/null || return 1
    date +%s > "$f" 2>/dev/null
}

# --- 日志模块 ---
source "${_LIB_DIR}/lib-tmux-ai-log.sh"

# --- 工具适配器加载 ---
# 每个 AI CLI 的差异（事件集/hooks路径/格式/完整性/进程名/SessionEnd/SessionStart时机）
# 抽到 adapters/<TOOL_ID>.sh，核心引擎读 adapter 暴露的变量/函数分派，不再写 case "$TOOL_ID"。
# 加新 CLI = 加一个 adapters/<tool>.sh，核心零改动。
_ADAPTER_DIR="${_LIB_DIR}/adapters"
_load_adapter() {
    local tool="${TOOL_ID:-claude}"
    local adapter="${_ADAPTER_DIR}/${tool}.sh"
    if [ -f "$adapter" ]; then
        source "$adapter"
    else
        _ai_log "ADAPTER: 未找到 ${adapter}，回退默认（claude）"
        [ -f "${_ADAPTER_DIR}/claude.sh" ] && source "${_ADAPTER_DIR}/claude.sh"
    fi
}
_load_adapter

# 跨 adapter 汇总所有 AI CLI 的进程名（供 _pane_has_ai_process 识别聚合场景下的
# 任意工具进程——聚合/清理路径需认全部工具，不止当前 TOOL_ID）。扫 adapters/*.sh
# 提取 ADAPTER_PROCESS_NAMES。惰性求值，缓存到 _ALL_AI_PROCESS_NAMES。
_ALL_AI_PROCESS_NAMES=""
_collect_ai_process_names() {
    [ -n "$_ALL_AI_PROCESS_NAMES" ] && { echo "$_ALL_AI_PROCESS_NAMES"; return; }
    local names="" f n
    for f in "${_ADAPTER_DIR}"/*.sh; do
        [ -f "$f" ] || continue
        # 提取 ADAPTER_PROCESS_NAMES="..." 的值（不 source，避免副作用）
        n=$(sed -n 's/^ADAPTER_PROCESS_NAMES="\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
        [ -n "$n" ] && names="$names $n"
    done
    # 去重
    _ALL_AI_PROCESS_NAMES=$(echo "$names" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
    echo "$_ALL_AI_PROCESS_NAMES"
}

# --- Per-pane 目录 ---
# 结构: ${_STATUS_DIR}/${PANE_SANITIZED}/
#   pane-${SESSION_ID}          session → pane 映射（内容为 pane_id）
#   pending-pre                 已收 PreToolUse、未收 PostToolUse 的 tool_use_id（每行 "id tool ts"）
#   pending-perm                已收 PermissionRequest、未配对的 tool_use_id（每行 "id !/? tool ts"）
#   .lock/                      修改 pending-* 时的 per-pane mkdir mutex
#   .event-lock/                串行化一次 hook 的 pending 变更、派生和 tmux option 写入

_pane_sanitized() {
    echo "${TMUX_PANE//[^a-zA-Z0-9]/_}"
}

_pane_dir() {
    [ -n "$TMUX_PANE" ] || return 1
    echo "${_STATUS_DIR}/$(_pane_sanitized)"
}

_ensure_pane_dir() {
    local dir; dir=$(_pane_dir) || return 1
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
}

# --- Pane 解析 ---
# 继承的 $TMUX_PANE 可能来自长期存活的进程（如 codex managed app-server daemon）。
# 关键：daemon 的继承值甚至可能指向当前 server 中真实存在、但与本会话无关的 pane，
# 所以「server pid 匹配 + pane 存在」不足以信任它。判定顺序：
#   1) 祖先链：hook 进程向上能否命中某个 pane 的 pane_pid（权威）
#   2) 祖先链不通 = daemon/脱离上下文 → 继承值一律丢弃
#   3) session 映射（带 server/pane_pid/tool/cwd 元数据校验）
#   4) 同工具进程树候选 → adapter 提示 → hook cwd 逐级收敛
# 只有收敛到唯一候选才采用；多候选不猜（保持空，由 monitor 显示 idle `-`）。

HOOK_CWD="${HOOK_CWD:-}"
_PANE_SNAPSHOT=""
_PANE_SNAPSHOT_OK=0
_CURRENT_SERVER_PID=""
_TMUX_PANE_SOURCE=""

# 一次性快照：pane_id|path|current_command|pane_pid|server_pid|attached|title
# title 放最后：read 会把剩余内容（含 '|'）并入最后一个变量。
_load_pane_snapshot() {
    _PANE_SNAPSHOT=""
    _PANE_SNAPSHOT_OK=0
    _CURRENT_SERVER_PID=""
    command -v tmux >/dev/null 2>&1 || return 1
    _PANE_SNAPSHOT=$(tmux list-panes -a -F \
        '#{pane_id}|#{s/[|]/_/:pane_current_path}|#{s/[|]/_/:pane_current_command}|#{pane_pid}|#{pid}|#{session_attached}|#{pane_title}' \
        2>/dev/null)
    [ -n "$_PANE_SNAPSHOT" ] || return 1
    _PANE_SNAPSHOT_OK=1
    _CURRENT_SERVER_PID=$(printf '%s\n' "$_PANE_SNAPSHOT" | awk -F'|' 'NR==1{print $5}')
    return 0
}

_snapshot_field() {  # $1=pane_id $2=字段号
    [ "$_PANE_SNAPSHOT_OK" = "1" ] || return 1
    printf '%s\n' "$_PANE_SNAPSHOT" | awk -F'|' -v id="$1" -v n="$2" '$1==id{print $n; exit}'
}

_snapshot_has_pane() {  # $1=pane_id
    [ "$_PANE_SNAPSHOT_OK" = "1" ] || return 1
    printf '%s\n' "$_PANE_SNAPSHOT" | awk -F'|' -v id="$1" '$1==id{found=1} END{exit !found}'
}

# 从当前进程沿父链向上匹配 pane_pid；命中即返回该 pane（权威信号）。
# $1 可选进程快照（_ps_process_snapshot 输出）：调用方（resolve_tmux_pane）
# 传入以复用同一份快照（ancestry 与进程树候选共用，每事件一次 ps）；空参自取。
# 一次 awk 同时建 ppid 映射与 pane_pid→pane_id 表，从 $$ 内存爬链——
# depth<24 / pid>1 语义与旧逐层 `ps -o ppid=` 版一致；快照是瞬时一致视图，
# 还消除了逐层实时 ps 的爬链中途进程死亡问题。
_pane_from_ancestry() {
    local snapshot="${1:-}"
    [ -n "$snapshot" ] || snapshot=$(_ps_process_snapshot)
    [ -n "$snapshot" ] || return 1
    # ps 快照与 pane 快照均为变量内容（非文件），各经 process substitution 进 awk：
    # 第一个文件（NR==FNR）建 ppid 映射，第二个建 pane_pid→pane_id 表，END 爬链。
    # ⚠️ split 必须用单空格 " "（awk 特殊语义：忽略前导/尾部空白、折叠连续分隔），
    # 不能用 /[ \t]+/——macOS ps 的 pid 列宽随快照最大 pid 位数浮动，4 位 pid 行
    # 带前导空格，正则 split 的首字段会是空串（pid 全部错位/丢弃），爬链在低位
    # pid 处断链——表现为偶发 PANE: unresolved（实测踩坑，2026-10-20）。
    awk -F'|' -v self="$$" '
        NR==FNR {
            split($0, a, " ")
            if (a[1] != "") ppid[a[1]] = a[2]
            next
        }
        $4 != "" { pane_by_pid[$4] = $1 }
        END {
            pid = self
            depth = 0
            while (pid + 0 > 1 && depth < 24) {
                if (pid in pane_by_pid) { print pane_by_pid[pid]; exit 0 }
                if (!(pid in ppid)) exit 1
                pid = ppid[pid] + 0
                depth++
            }
            exit 1
        }' <(printf '%s\n' "$snapshot") <(printf '%s\n' "${_PANE_SNAPSHOT:-}")
}

# 当前工具在 attached pane 中的候选集合（进程树含 ADAPTER_PROCESS_NAMES）。
# $1 可选进程快照：透传给 _pid_tree_has_names，避免每个候选 pane 各起一次 ps。
_pane_process_candidates() {
    local names="${ADAPTER_PROCESS_NAMES:-}" snapshot="${1:-}" id path cmd pid server attached title
    [ -n "$names" ] || return 1
    [ "$_PANE_SNAPSHOT_OK" = "1" ] || return 1
    while IFS='|' read -r id path cmd pid server attached title; do
        [ -n "$id" ] || continue
        [ "${attached:-0}" -gt 0 ] || continue
        if _pid_tree_has_names "$pid" "$names" "$snapshot"; then printf '%s\n' "$id"; fi
    done <<EOF
$_PANE_SNAPSHOT
EOF
}

# 取交集（按 $1 的顺序）；过滤结果为空时保持原集合。
_intersect_panes() {
    local base="$1" filter="$2" out="" p
    [ -n "$filter" ] || { printf '%s\n' "$base"; return; }
    filter=$(printf '%s' "$filter" | tr '\n' ' ')
    for p in $base; do
        case " $filter " in *" $p "*) out="$out $p" ;; esac
    done
    [ -n "$out" ] && printf '%s\n' "${out# }" || printf '%s\n' "$base"
}

_narrow_panes_by_adapter() {
    local base="$1" hints=""
    declare -f adapter_pane_hints >/dev/null 2>&1 || { printf '%s\n' "$base"; return; }
    hints=$(adapter_pane_hints "${SESSION_ID:-}" "$HOOK_CWD" 2>/dev/null)
    _intersect_panes "$base" "$hints"
}

_narrow_panes_by_cwd() {
    local base="$1" want="" matches="" id path cmd pid server attached title
    [ -n "${HOOK_CWD:-}" ] || { printf '%s\n' "$base"; return; }
    # _normalize_path 对非空输入恒返回 0（cd 失败时返回去尾斜杠原串），无需兜底分支
    want=$(_normalize_path "$HOOK_CWD")
    while IFS='|' read -r id path cmd pid server attached title; do
        [ -n "$id" ] || continue
        [ "$(_normalize_path "$path")" = "$want" ] && matches="$matches $id"
    done <<EOF
$_PANE_SNAPSHOT
EOF
    _intersect_panes "$base" "$matches"
}

# 路径归一化：去尾斜杠 + 解析符号链接（解析失败时保留原路径）。
_normalize_path() {
    local p="$1" phys
    [ -n "$p" ] || return 1
    while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
    phys=$(cd "$p" 2>/dev/null && pwd -P) && p="$phys"
    printf '%s' "$p"
}

# 标题归一化：仅剥已知前缀（✳ / *）与首尾空白；不删非字母字符，避免破坏中文。
_normalize_title() {
    local t="$1"
    t=$(printf '%s' "$t" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$t" in
        "✳"*) t="${t#✳}" ;;
        "*"*)  t="${t#\*}" ;;
    esac
    printf '%s' "$t" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# 解析失败的负缓存：避免 daemon 高频事件反复枚举 pane + BFS。
_resolve_negative_path() { printf '%s/.resolve-ts-%s' "$_STATUS_DIR" "${SESSION_ID:-unknown}"; }
_resolve_recently_failed() {
    local f ts age
    f=$(_resolve_negative_path)
    [ -f "$f" ] || return 1
    ts=$(cat "$f" 2>/dev/null)
    [ -n "$ts" ] || return 1
    age=$(( $(date +%s) - ts ))
    [ "$age" -ge 0 ] && [ "$age" -lt 5 ]
}
_mark_resolve_failed() {
    mkdir -p "$_STATUS_DIR" 2>/dev/null || true
    date +%s > "$(_resolve_negative_path)" 2>/dev/null || true
}
_clear_resolve_failed() { rm -f "$(_resolve_negative_path)" 2>/dev/null || true; }

resolve_tmux_pane() {
    local inherited="${TMUX_PANE:-}" pane candidates n

    TMUX_PANE=""
    _TMUX_PANE_SOURCE=""

    # 1) 祖先链是权威信号（普通启动 / 旧 cc-switch / Claude 的 pane 内 hook）
    _load_pane_snapshot || return 1
    # 进程快照取一次，ancestry 爬链与进程树候选共用（每事件 1 次 ps 而非 4-6 次）
    local ps_snap
    ps_snap=$(_ps_process_snapshot)
    pane=$(_pane_from_ancestry "$ps_snap")
    if [ -n "$pane" ]; then
        TMUX_PANE="$pane"
        _TMUX_PANE_SOURCE="ancestry"
        if [ -n "$inherited" ] && [ "$inherited" != "$pane" ]; then
            _ai_log "PANE: inherited '$inherited' overridden by ancestry '$pane' (tool=$TOOL_ID)"
        fi
        _clear_resolve_failed
        return 0
    fi

    # 2) 祖先链没有 pane = daemon / 脱离上下文：继承值可能指向当前 server 中
    #    真实存在但无关的 pane，一律丢弃，走映射与多信号收敛。
    if [ -n "${SESSION_ID:-}" ] && _load_pane_id; then
        _TMUX_PANE_SOURCE="mapping"
        _clear_resolve_failed
        return 0
    fi

    if _resolve_recently_failed; then
        return 1
    fi

    # 3) 同工具进程树候选 → adapter 提示 → hook cwd
    candidates=$(_pane_process_candidates "$ps_snap")
    if [ -n "$candidates" ]; then
        n=$(printf '%s\n' "$candidates" | grep -c .)
        if [ "$n" -gt 1 ]; then
            candidates=$(_narrow_panes_by_adapter "$candidates")
            n=$(printf '%s\n' "$candidates" | grep -c .)
        fi
        if [ "$n" -gt 1 ] && [ -n "${HOOK_CWD:-}" ]; then
            candidates=$(_narrow_panes_by_cwd "$candidates")
            n=$(printf '%s\n' "$candidates" | grep -c .)
        fi
        if [ "$n" -eq 1 ]; then
            TMUX_PANE="${candidates%%$'\n'*}"
            _TMUX_PANE_SOURCE="process"
            _clear_resolve_failed
            _ai_log "PANE: '$inherited' → '$TMUX_PANE' (tool=$TOOL_ID, detached, resolved)"
            return 0
        fi
    fi

    _mark_resolve_failed
    _ai_log "PANE: unresolved (inherited='${inherited}' tool=$TOOL_ID session=${SESSION_ID:-?} cwd=${HOOK_CWD:-?} candidates='${candidates:-}')"
    return 1
}

# --- Pane ID 持久化（供后续事件/SessionEnd 回读）---
# 映射文件 pane-${SESSION_ID} 保持单行 pane id（既有清理逻辑依赖）；
# 旁路 .pane-meta-${SESSION_ID} 记录 tool/server_pid/pane_pid/cwd，用于识别
# 「server 重启后 pane id 被复用」等陈旧映射。只有成功解析（_TMUX_PANE_SOURCE
# 非空）才落盘，避免把猜测持久化。
_save_pane_id() {
    [ -n "$TMUX_PANE" ] && [ -n "${SESSION_ID:-}" ] || return 0
    [ -n "${_TMUX_PANE_SOURCE:-}" ] || return 0
    _ensure_pane_dir || return 0
    local dir
    dir=$(_pane_dir) || return 0
    printf '%s\n' "$TMUX_PANE" > "$dir/pane-${SESSION_ID}"
    if [ "$_PANE_SNAPSHOT_OK" = "1" ]; then
        printf '1\t%s\t%s\t%s\t%s\n' \
            "${TOOL_ID:-}" "${_CURRENT_SERVER_PID:-}" \
            "$(_snapshot_field "$TMUX_PANE" 4)" "$(_snapshot_field "$TMUX_PANE" 2)" \
            > "$dir/.pane-meta-${SESSION_ID}" 2>/dev/null || true
    fi
}
_load_pane_id() {
    [ -n "${SESSION_ID:-}" ] || return 1
    [ "$_PANE_SNAPSHOT_OK" = "1" ] || return 1
    local f pane dir meta ver mtool mserver mpid mpath cpid
    for f in "${_STATUS_DIR}"/*/pane-${SESSION_ID}; do
        [ -f "$f" ] || continue
        pane=$(head -n 1 "$f" 2>/dev/null)
        [ -n "$pane" ] || continue
        dir="${f%/*}"
        meta="$dir/.pane-meta-${SESSION_ID}"

        # pane 已不存在：确定失效，连元数据一起删除
        if ! _snapshot_has_pane "$pane"; then
            rm -f "$f" "$meta" 2>/dev/null || true
            continue
        fi
        # 旧版映射（无 meta）不可信：忽略，让本次重新解析覆盖
        [ -f "$meta" ] || continue
        IFS=$'\t' read -r ver mtool mserver mpid mpath < "$meta"
        [ "$ver" = "1" ] || continue
        [ "$mtool" = "${TOOL_ID:-}" ] || continue
        [ -n "$_CURRENT_SERVER_PID" ] && [ "$mserver" = "$_CURRENT_SERVER_PID" ] || continue
        cpid=$(_snapshot_field "$pane" 4)
        [ "$mpid" = "$cpid" ] || continue
        # hook cwd 与映射时的 pane 路径不一致 → 会话已迁移，不采用
        if [ -n "${HOOK_CWD:-}" ] && [ -n "$mpath" ]; then
            [ "$(_normalize_path "$mpath")" = "$(_normalize_path "$HOOK_CWD")" ] || continue
        fi

        TMUX_PANE="$pane"
        return 0
    done
    return 1
}
_clear_pane_id() {
    [ -n "$TMUX_PANE" ] && [ -n "${SESSION_ID:-}" ] || return 0
    local dir; dir=$(_pane_dir) || return 0
    rm -f "$dir/pane-${SESSION_ID}" "$dir/.pane-meta-${SESSION_ID}" 2>/dev/null
}

# --- cc-switch provider 标签 ---
# cc-switch(switch 命令)launch 时向 CLI 注入 CC_SWITCH_PROVIDER / CC_SWITCH_PROVIDER_ID,
# CLI 的 hooks 进程继承之;tmux-ai-status 入口把它们捕获进 pane option
# @ai_provider / @ai_provider_id。聚合侧在此读取并渲染彩色 provider 段。
# 颜色真源:~/.cc-switch/statusline-preferences.json(colors.claude / colors.codex
# 按 providerId 分桶)——与 cc-switch wrapper 状态栏标签同一真源,TUI `o` 改色
# 下一次 rebuild 即生效。显式值是 ANSI SGI 码(30-37/90-97),映射 tmux colourN
# (30-37 → 0-7,90-97 → 8-15);缺省 auto = FNV-1a(name)落在 cc-switch wrapper
# 同款 6 色 bright 调色板上。JS Math.imul 是 32 位截断乘;64 位精确积 & 0xFFFFFFFF
# 与之同余,纯 bash 可复刻(非 ASCII 名按字节遍历,与 JS 码点遍历 hash 可能不同,
# 只影响 auto 落点,非错误)。
_PROVIDER_PREFS_LINES=""
_PROVIDER_PREFS_LOADED=""
_provider_prefs_lines() {
    if [ -z "$_PROVIDER_PREFS_LINES" ] && [ -z "$_PROVIDER_PREFS_LOADED" ]; then
        _PROVIDER_PREFS_LOADED=1
        local f="${HOME}/.cc-switch/statusline-preferences.json"
        if [ -f "$f" ]; then
            # claude/codex 两桶浅合并:providerId 是 uuid,跨桶不冲突
            _PROVIDER_PREFS_LINES=$(jq -r '((.colors.claude // {}) + (.colors.codex // {})) | to_entries[] | "\(.key)=\(.value)"' "$f" 2>/dev/null)
        fi
    fi
    printf '%s' "$_PROVIDER_PREFS_LINES"
}

_provider_tag_colour() {
    local id="$1" name="$2" v=""
    if [ -n "$id" ]; then
        v=$(printf '%s\n' "$(_provider_prefs_lines)" | awk -F= -v id="$id" '$1==id{print $2; exit}')
    fi
    case "$v" in
        3[0-7]) echo $(( v - 30 )); return ;;
        9[0-7]) echo $(( v - 82 )); return ;;
    esac
    # auto: FNV-1a 32 位
    local hash=2166136261 i ch cp
    for ((i=0; i<${#name}; i++)); do
        ch="${name:$i:1}"
        printf -v cp '%d' "'$ch"
        hash=$(( (hash ^ cp) * 16777619 & 4294967295 ))
    done
    case $(( hash % 6 )) in
        0) echo 96 ;; 1) echo 92 ;; 2) echo 93 ;; 3) echo 95 ;; 4) echo 94 ;; 5) echo 91 ;;
    esac
}

# --- 状态聚合 ---
# 扫描所有 attached session 的 pane，读取 @ai_pane_status，写入 @ai_all_status
#
# 空窗期补 idle：codex 的 SessionStart hook 延迟到首个 turn 才触发（上游 run_pending_
# session_start_hooks 设计），空闲蹲在提示符时插件收不到任何事件 → 无 @ai_pane_status。
# 用 pane_current_command 兜底：前台命令是 codex/claude 但无显式状态时，显示 idle `-`。
# 纯显示，不落 @ai_pane_status（避免污染 pending/cleanup 逻辑）。零进程扫描。
build_all_status() {
    ALL=""
    cur_sess=""
    local _ai_names _fmt _n
    _ai_names=$(_collect_ai_process_names)
    # 动态追加上 monitor 的 seen 标记（无 SessionEnd 工具的进程树探测结果）。
    # switch/volta-shim 启动的 pane 前台命令不是 codex，必须靠该标记补 idle `-`。
    # 自由文本字段就地消毒：tmux format 的 s/[|]/_/ 替换（`|` 是 ERE 交替符，
    # 必须写成 [|] 或 \|；裸 s/|/…/ 不生效）。session 名/provider 名含 `|` 时
    # 会劈裂字段——attached 位变状态字符使 $6>0 误判、该 session 整行消失。
    _fmt="#{pane_id}|#{s/[|]/_/:session_name}|#{window_index}|#{pane_index}|#{@ai_pane_status}|#{session_attached}|#{session_created}|#{@ai_entered_time}|#{s/[|]/_/:pane_current_command}|#{s/[|]/_/:@ai_provider}|#{s/[|]/_/:@ai_provider_id}"
    for _n in $_ai_names; do
        _fmt="$_fmt|#{@ai_monitor_seen_$_n}"
    done
    while IFS='|' read -r pane_id session_name win_idx pane_idx claude_status _attached _created _entered cur_cmd prov_name prov_id _seen_flags; do
        local pane_status="$claude_status"
        if [ -z "$pane_status" ]; then
            # 无显式状态：若前台是 AI 进程（codex 首个 turn 前空窗期），补 idle。
            # 进程名集合从所有 adapter 汇总，前缀匹配（codex-aarch64-* 等）。
            # 前台命令是 switch/volta-shim 时改为读 monitor 的进程树标记。
            local _cmd_base _n _is_ai=0
            _cmd_base=$(basename "$cur_cmd" 2>/dev/null)
            for _n in $_ai_names; do
                case "$_cmd_base" in
                    "$_n"|"$_n"-*|"$_n"_*) _is_ai=1; break ;;
                esac
            done
            if [ "$_is_ai" = "0" ]; then
                case "$_seen_flags" in *1*) _is_ai=1 ;; esac
            fi
            [ "$_is_ai" = "1" ] && pane_status="-" || continue
        fi
        local session_block="#[bg=#6272A4,fg=#F8F8F2] ${session_name} #[bg=default,fg=default]"
        local panel_block="#[bg=#44475A,fg=#BD93F9] ${win_idx}.${pane_idx} #[bg=default,fg=default]"
        local status_block
        if [ "$pane_status" = "!" ] || [ "$pane_status" = "?" ]; then
            status_block="#[bg=#FF5555,fg=#F8F8F2] ${pane_status} #[bg=default,fg=default]"
        elif [ "$pane_status" = ">" ]; then
            status_block="#[bg=#50FA7B,fg=#282A36] ${pane_status} #[bg=default,fg=default]"
        else
            status_block="#[bg=${STATUS_COLOR},fg=#282A36] ${pane_status} #[bg=default,fg=default]"
        fi
        local seg="${panel_block}${status_block}"
        # cc-switch provider 段:有 @ai_provider 才显示(非 switch 启动的 pane 无此 option)
        if [ -n "$prov_name" ]; then
            local prov_colour
            prov_colour=$(_provider_tag_colour "$prov_id" "$prov_name")
            seg="${seg}#[fg=colour${prov_colour}][${prov_name}] #[fg=default]"
        fi
        if [ "$session_name" != "$cur_sess" ]; then
            ALL="${ALL:+$ALL  }${session_block}${seg}"
            cur_sess="$session_name"
        else
            ALL="${ALL}${seg}"
        fi
    # 排序两级键：① @ai_entered_time（client-session-changed 时由 _session-switched
    # 写入的「真进入」时间，刚进入的 session 排最后；attach 与 switch-client 都触发，
    # 自指 switch 由 handler 的 per-client prev 对比滤除）
    # ② session_created（无进入记录时回退创建序）。不用 session_last_attached——
    # tmux 的 server_client_set_session 无条件刷新该时间戳（自指 switch 也算），污染排序。
    done < <(tmux list-panes -a -F "$_fmt" 2>/dev/null | awk -F'|' -v OFS='|' '$6>0{if($8=="")$8=$7; print}' | sort -t'|' -k8,8n -k7,7n -k2,2 -k3,3n -k4,4n)
}

# --- Pending 集合管理（PreToolUse / PermissionRequest 配对）---
# 状态判定基于两个 per-pane 集合（另有一个乱序辅助集合）:
#   pending-pre   : 已 PreToolUse 未 PostToolUse 的 tool_use_id（行 "id tool hash ts"）
#   pending-perm  : 已 PermissionRequest 未配对的 tool_use_id（行 "id mark tool hash ts"）
#   recent-post   : 已 PostToolUse 完成的 tool_use_id（行 "id ts"）
#                   Post 先于 Pre 到达时，迟到的 Pre 据此跳过写入，避免状态卡 ">"
# hash = tool_name + 规范化 tool_input 的指纹，用于把 Claude 无 tool_use_id 的
# PermissionRequest 精确绑定到对应的 PreToolUse；旧格式行没有 hash 列时读作 "-"。
# 派生规则:
#   perm 含 "!"   → STATUS=!
#   perm 含 "?"   → STATUS=?
#   pre 非空      → STATUS=>
#   都空          → STATUS=""（事件自行决定）

_PENDING_DONE_WINDOW=60    # 迟到 Pre 的拦截窗口（tool_use_id 单次唯一，10x 余量）
_PENDING_DONE_RETAIN=300   # recent-post 保留时长（写时修剪）

_pending_pre_path()  { echo "$(_pane_dir)/pending-pre"; }
_pending_perm_path() { echo "$(_pane_dir)/pending-perm"; }
_pending_done_path() { echo "$(_pane_dir)/recent-post"; }
_lock_dir()          { echo "$(_pane_dir)/.lock"; }
_event_lock_dir()    { echo "$(_pane_dir)/.event-lock"; }

# 按 pane_id 推导状态目录/文件路径（_cleanup_stale_panes 等跨 pane 场景用）。
_pane_dir_by_id()       { printf '%s/%s' "$_STATUS_DIR" "${1//[^a-zA-Z0-9]/_}"; }
_pending_pre_path_for() { printf '%s/pending-pre' "$(_pane_dir_by_id "$1")"; }
_pending_perm_path_for(){ printf '%s/pending-perm' "$(_pane_dir_by_id "$1")"; }

# tool_name + 规范化 tool_input 的短指纹（16 hex）。PermissionRequest 与
# PreToolUse 的 tool_input 是同一个对象，规范化后应逐字节一致；任一侧缺失时
# 返回 "-"，调用方退化为同工具 LIFO 绑定。哈希命令按 shasum → sha256sum →
# md5 → md5sum → sha1sum 探测，全缺时恒返回 "-"（绑定仍可用）。
_HASH_CMD=""
_HASH_CMD_DONE=""
_permission_input_hash() {  # $1=tool_name $2=原始 hook JSON
    local tool="$1" canon
    canon=$(printf '%s' "$2" | jq -S -c 'if (.tool_input? != null) then .tool_input else empty end' 2>/dev/null)
    [ -n "$canon" ] || { printf '%s' "-"; return; }
    if [ -z "$_HASH_CMD_DONE" ]; then
        if command -v shasum >/dev/null 2>&1; then _HASH_CMD="shasum -a 256"
        elif command -v sha256sum >/dev/null 2>&1; then _HASH_CMD="sha256sum"
        elif command -v md5 >/dev/null 2>&1; then _HASH_CMD="md5 -q"
        elif command -v md5sum >/dev/null 2>&1; then _HASH_CMD="md5sum"
        elif command -v sha1sum >/dev/null 2>&1; then _HASH_CMD="sha1sum"
        fi
        _HASH_CMD_DONE=1
    fi
    [ -n "$_HASH_CMD" ] || { printf '%s' "-"; return; }
    # shellcheck disable=SC2086  # 命令可能带参数（shasum -a 256 / md5 -q）
    printf '%s\n%s' "$tool" "$canon" | $_HASH_CMD 2>/dev/null | awk '{print $1}' | cut -c1-16
}

# 审批证据：写盘总闸/清理路径用。$1=live 标记（!/?），$2=可选 pane_id。
#   1) pending-perm 非空 → 仍有未解除的审批
#   2) live 为 '?' 且 pending-pre 里有 AskUserQuestion 项 → 问题还没收到 Post
# 命中时设置 EVIDENCE_SRC 供日志/测试断言。
_has_pending_approval_evidence() {  # $1=mark [$2=pane_id]
    local mark="$1" pane="${2:-}" perm pre
    if [ -n "$pane" ]; then
        perm=$(_pending_perm_path_for "$pane")
        pre=$(_pending_pre_path_for "$pane")
    else
        perm=$(_pending_perm_path)
        pre=$(_pending_pre_path)
    fi
    [ -s "$perm" ] && { EVIDENCE_SRC="pending-perm"; return 0; }
    case "$mark" in
        "?") awk '$2=="AskUserQuestion"{f=1;exit} END{exit !f}' "$pre" 2>/dev/null \
                 && { EVIDENCE_SRC="auq-pre"; return 0; } ;;
    esac
    return 1
}

# 串行化同 pane 的完整事件处理，避免 pending 变更后、tmux option 写入前被其他 hook
# 插入，导致较晚写入的过期派生结果覆盖审批态。使用独立锁，允许事件内部继续使用 .lock。
# $1 可选最大重试次数（默认 200 ≈ 2s）；Esc 等交互路径用短预算。
_acquire_event_lock() {
    [ -n "$TMUX_PANE" ] || return 1
    _ensure_pane_dir
    local max="${1:-200}"
    local lock; lock=$(_event_lock_dir)
    # 重试预算 ~2s。sleep 0.01 不被支持时退化为无 sleep 自旋（mkdir+stat 系统调用，
    # ~几百 ms 耗尽预算）——绝不能回落 sleep 1：200×1s 病态忙等，而 sync hook 的
    # 上游 timeout 是 600s，不会打断它（实测 macOS/Linux sleep 均支持小数，此为
    # 其他平台兜底）。时间基准用 $SECONDS（builtin，零 fork；date +%s 每迭代一次 fork）。
    local _start=$SECONDS
    local i=0
    while [ "$i" -lt "$max" ]; do
        i=$((i + 1))
        if mkdir "$lock" 2>/dev/null; then
            echo "$$" > "$lock/owner"
            return 0
        fi
        local owner mtime
        owner=$(cat "$lock/owner" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$lock/owner" 2>/dev/null
            rmdir "$lock" 2>/dev/null
            continue
        fi
        mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null)
        if [ -n "$mtime" ] && [ $(( _start + SECONDS - mtime )) -ge 10 ]; then
            rm -f "$lock/owner" 2>/dev/null
            rmdir "$lock" 2>/dev/null
        fi
        sleep 0.01 2>/dev/null || :
    done
    _ai_log "EVENT_LOCK: acquire timeout on $lock"
    return 1
}

_release_event_lock() {
    [ -n "$TMUX_PANE" ] || return
    rm -f "$(_event_lock_dir)/owner" 2>/dev/null
    rmdir "$(_event_lock_dir)" 2>/dev/null
}

# 事件锁超时时 PermissionRequest 的无锁降级写入（仅 !/? 这类最强状态可无锁写，
# 调用点见 tmux-ai-status 锁段落的原则注释）。
# 最小动作集：一次 jq 取 tool_name → AskUserQuestion ? / 其他 ! → set-option →
# 日志标记 DOWNGRADE。随后无锁 append 一条审批证据（pending-perm）：锁已被其他
# 事件持有，_acquire_lock 必然超时；单行 append 是 O_APPEND 原子写，不竞争 .lock。
# 不跑 _save_pane_id（锁外写 pane 映射有复活已清映射的风险）、不做 build_all_status
# （monitor 每秒重建聚合，降级值 ≤1s 内可见）。
_downgrade_permission_request() {  # $1=原始 stdin JSON
    local input="$1" tool status hash
    tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
    if [ "$tool" = "AskUserQuestion" ]; then
        status="?"
    else
        status="!"
    fi
    tmux set-option -pt "$TMUX_PANE" @ai_pane_status "$status" 2>/dev/null || true
    hash=$(_permission_input_hash "$tool" "$input")
    printf '%s.%s.%s.%s-%s %s %s %s %s\n' \
        "__unmatched_permission__" "$hash" "$(date +%s)" "$$" "$RANDOM" \
        "$status" "${tool:-?}" "$hash" "$(date +%s)" \
        >> "$(_pending_perm_path)" 2>/dev/null || true
    _pane_loc=""
    _ai_log "PermReq DOWNGRADE: event lock timeout, unlocked write '$status' (tool=${tool:-?} hash=${hash})"
}

# Per-pane mkdir mutex。5s stale 强夺。retry 20 × 10ms ≈ 200ms 上限。
# sleep 回落策略同 _acquire_event_lock（不支持小数 sleep 时无 sleep 自旋，不回落 sleep 1）。
_acquire_lock() {
    [ -n "$TMUX_PANE" ] || return 1
    _ensure_pane_dir
    local lock; lock=$(_lock_dir)
    local _start=$SECONDS
    local i
    for i in {1..20}; do
        if mkdir "$lock" 2>/dev/null; then
            return 0
        fi
        # stale 检测: 锁目录 mtime > 5s 视为遗弃
        local mtime
        mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null)
        if [ -n "$mtime" ]; then
            local age=$(( _start + SECONDS - mtime ))
            if [ "$age" -ge 5 ]; then
                rmdir "$lock" 2>/dev/null
                mkdir "$lock" 2>/dev/null && return 0
            fi
        fi
        sleep 0.01 2>/dev/null || :
    done
    _ai_log "LOCK: acquire timeout on $lock"
    return 1
}

_release_lock() {
    [ -n "$TMUX_PANE" ] || return
    rmdir "$(_lock_dir)" 2>/dev/null
}

# --- recent-post（已完成 id 的 tombstone）---
# 调用方必须持 .lock。只读：id 是否在窗口内已完成。
_recent_done_has() {  # $1=id
    local id="$1" f now
    [ -n "$id" ] || return 1
    f=$(_pending_done_path)
    [ -s "$f" ] || return 1
    now=$(date +%s)
    awk -v id="$id" -v now="$now" -v max="$_PENDING_DONE_WINDOW" '
        $1 == id && $2 ~ /^[0-9]+$/ && now - $2 <= max { found = 1; exit }
        END { exit !found }' "$f" 2>/dev/null
}

# 调用方必须持 .lock。一次 awk 同时完成「同 id 去重 + 过期修剪 + 追加」。
_record_pending_done() {  # $1=id
    local id="$1" f now tmp
    [ -n "$id" ] || return 0
    f=$(_pending_done_path)
    now=$(date +%s)
    tmp="${f}.tmp.$$"
    if [ -f "$f" ]; then
        awk -v id="$id" -v cutoff="$((now - _PENDING_DONE_RETAIN))" '
            $1 != id && $2 ~ /^[0-9]+$/ && $2 >= cutoff { print }' "$f" > "$tmp" 2>/dev/null
    else
        : > "$tmp"
    fi
    printf '%s %s\n' "$id" "$now" >> "$tmp"
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# 调用方必须持 .lock。按首列精确比较（id 可能含 . [ 等 BRE 元字符）。
_remove_pending_id_locked() {  # $1=id
    local id="$1" pre perm
    [ -n "$id" ] || return 0
    pre=$(_pending_pre_path)
    perm=$(_pending_perm_path)
    if [ -f "$pre" ]; then
        awk -v id="$id" '$1 != id' "$pre" > "${pre}.tmp" 2>/dev/null
        mv -f "${pre}.tmp" "$pre" 2>/dev/null || rm -f "${pre}.tmp"
    fi
    if [ -f "$perm" ]; then
        awk -v id="$id" '$1 != id' "$perm" > "${perm}.tmp" 2>/dev/null
        mv -f "${perm}.tmp" "$perm" 2>/dev/null || rm -f "${perm}.tmp"
    fi
}

# 在锁内追加一行到 pending-pre。$1=tool_use_id $2=tool_name [$3=hash]
# Post 已先到达的同 id（recent-post 窗口内）→ 跳过并置 _pending_pre_skipped=1，
# 调用方据此保持已完成状态（不能把迟到的 Pre 重新抬成处理中/审批态）。
_pending_pre_skipped=0
_add_pending_pre() {
    local id="$1" tool="$2" hash="${3:--}" pre
    _pending_pre_skipped=0
    [ -z "$id" ] && return 0
    _acquire_lock || return 0
    pre=$(_pending_pre_path)
    if _recent_done_has "$id"; then
        _pending_pre_skipped=1
        # 防御：Post 的清理曾因 IO/锁失败残留同 id 时，顺手清掉
        _remove_pending_id_locked "$id"
    elif ! awk -v id="$id" '$1 == id { found = 1; exit } END { exit !found }' "$pre" 2>/dev/null; then
        printf '%s %s %s %s\n' "$id" "${tool:-?}" "$hash" "$(date +%s)" >> "$pre"
    fi
    _release_lock
    if [ "$_pending_pre_skipped" = "1" ]; then
        _ai_log "PENDING: SKIP stale Pre id=${id} tool=${tool:-?} (completed within ${_PENDING_DONE_WINDOW}s)"
    fi
}

# 在锁内追加一行到 pending-perm。$1=id $2=! 或 ? $3=tool_name [$4=hash]
# 同 id 已存在不重复（并行审批的 id 各不相同，不能按 tool/hash 合并）。
_add_pending_perm() {
    local id="$1" mark="$2" tool="$3" hash="${4:--}"
    [ -z "$id" ] && return
    _acquire_lock || return
    local f; f=$(_pending_perm_path)
    # 首列精确比较（id 可能含 BRE 元字符）
    if ! awk -v id="$id" '$1 == id { found = 1; exit } END { exit !found }' "$f" 2>/dev/null; then
        printf '%s %s %s %s %s\n' "$id" "$mark" "${tool:-?}" "$hash" "$(date +%s)" >> "$f"
    fi
    _release_lock
}

# PermissionRequest 缺少 ID 时绑定到候选 PreToolUse。
#   $1=mark $2=tool [$3=请求侧 hash]
# 严格模式（ADAPTER_PERMISSION_HASH_BINDING=true，Claude）：
#   - 同 tool、未绑定、300s 内的 Pre 中，hash 完全相等的优先（取最新）；
#   - 请求或候选 hash 为 "-"（缺失）时允许同工具 LIFO 兜底；
#   - 双方 hash 已知且不等 → 不绑定（交给唯一 sentinel 保守保持）。
# 非严格模式（Codex/OpenCode）：保持原有同工具 LIFO 语义。
# 成功时 BOUND_PERMISSION_ID=真实 tool_use_id，并追加 5 列 perm 行。
_bind_pending_perm_to_pre() {
    local mark="$1" tool="$2" req_hash="${3:--}"
    local strict="${ADAPTER_PERMISSION_HASH_BINDING:-false}"
    BOUND_PERMISSION_ID=""
    _acquire_lock || return 1
    local pre; pre=$(_pending_pre_path)
    local perm; perm=$(_pending_perm_path)
    local choice
    choice=$(awk -v perm="$perm" -v tool="${tool:-?}" -v req_hash="$req_hash" \
                -v strict="$strict" -v now="$(date +%s)" '
        BEGIN { while ((getline line < perm) > 0) { split(line, p, " "); bound[p[1]] = 1 } }
        {
            id = $1
            if (id == "" || $2 != tool || (id in bound)) next
            if (NF >= 4) { h = $3; ts = $NF } else { h = "-"; ts = $3 }
            if (ts ~ /^[0-9]+$/ && (now - ts) > 300) next
            if (req_hash != "-" && h != "-" && h == req_hash) {
                if (exact == "" || (ts + 0) >= exact_ts) { exact = id; exact_ts = ts + 0 }
            } else if (h == "-") {
                if (unk == "" || (ts + 0) >= unk_ts) { unk = id; unk_ts = ts + 0 }
            }
            if (any == "" || (ts + 0) >= any_ts) { any = id; any_ts = ts + 0 }
        }
        END {
            if (exact != "") { print "exact " exact; exit }
            if (strict == "true") {
                if (req_hash == "-") { if (any != "") print "tool-lifo " any }
                else if (unk != "") print "tool-lifo " unk
            } else if (any != "") {
                print "tool-lifo " any
            }
        }' "$pre" 2>/dev/null)
    if [ -n "$choice" ]; then
        BOUND_PERMISSION_ID="${choice#* }"
        printf '%s %s %s %s %s\n' "$BOUND_PERMISSION_ID" "$mark" "${tool:-?}" "$req_hash" "$(date +%s)" >> "$perm"
        _ai_log "BIND: ${choice%% *} id=${BOUND_PERMISSION_ID} tool=${tool:-?} hash=${req_hash}"
    else
        _ai_log "BIND: none tool=${tool:-?} hash=${req_hash} (sentinel)"
    fi
    _release_lock
    [ -n "$BOUND_PERMISSION_ID" ]
}

# PreToolUse 迟到（PermissionRequest 已写 sentinel）时反向绑定：把同 tool 的
# sentinel 行首列替换为真实 tool_use_id，使之后的 PostToolUse 能精确解除。
#   $1=id $2=tool [$3=hash]
# hash 已知：只替换 hash 相等的 sentinel；hash 未知：仅当同 tool sentinel 唯一。
# 替换失败返回 1，sentinel 保守保持到显式重置。
_rebind_sentinel_to_pre() {
    local id="$1" tool="$2" req_hash="${3:--}"
    [ -n "$id" ] || return 1
    _acquire_lock || return 1
    local perm; perm=$(_pending_perm_path)
    local hit=1
    if [ -f "$perm" ]; then
        local lineno
        lineno=$(awk -v tool="${tool:-?}" -v req_hash="$req_hash" '
            BEGIN { count = 0; pick = 0; pick_exact = 0 }
            index($1, "__unmatched_permission__") == 1 && $3 == tool {
                count++
                h = (NF >= 5 ? $4 : "-")
                if (req_hash != "-" && h == req_hash) {
                    if (pick_exact == 0) { pick = NR; pick_exact = 1 }
                } else if (req_hash == "-" && pick == 0) {
                    pick = NR
                }
            }
            END {
                if (req_hash != "-") { if (pick_exact == 1) print pick }
                else if (count == 1) print pick
            }' "$perm" 2>/dev/null)
        if [ -n "$lineno" ]; then
            if awk -v line="$lineno" -v id="$id" '
                    NR == line { $1 = id; print; next } { print }' "$perm" > "${perm}.tmp" 2>/dev/null \
               && mv -f "${perm}.tmp" "$perm" 2>/dev/null; then
                hit=0
                _ai_log "BIND: reverse-ok id=$id tool=${tool:-?} hash=$req_hash"
            else
                rm -f "${perm}.tmp" 2>/dev/null
            fi
        fi
    fi
    [ "$hit" = "0" ] || _ai_log "BIND: reverse-none id=$id tool=${tool:-?} hash=$req_hash"
    _release_lock
    return "$hit"
}

# 从 pending-pre 和 pending-perm 同时移除 id（配对清除）。
# 无论 pending 文件是否存在都记录 tombstone：Post 先于 Pre 到达时，后者是唯一
# 能拦住迟到 Pre 的证据（见 _add_pending_pre）。
_remove_pending_id() {
    local id="$1"
    [ -z "$id" ] && return 0
    _acquire_lock || return 0
    _record_pending_done "$id"
    _remove_pending_id_locked "$id"
    _release_lock
}

# 仅移除已回复的权限请求。OpenCode 的 request ID 与 tool call ID 独立，不能同时清
# pending-pre；后续 PostToolUse 会用 call ID 清理工具执行项。
# 不记 tombstone：request id 与 callID 命名空间不同，记了也拦不到迟到的 Pre。
_remove_pending_perm_id() {
    local id="$1"
    [ -z "$id" ] && return
    _acquire_lock || return
    local perm; perm=$(_pending_perm_path)
    if [ -f "$perm" ]; then
        awk -v id="$id" '$1 != id' "$perm" > "${perm}.tmp" 2>/dev/null
        mv -f "${perm}.tmp" "$perm" 2>/dev/null || rm -f "${perm}.tmp"
    fi
    _release_lock
}

# 清空两个 pending 文件（Stop/SessionStart/SessionEnd/UserPromptSubmit/Esc 用）。
# recent-post 刻意不清：turn/session 边界之后仍可能收到同 turn 迟到的 Pre，
# 删掉 tombstone 会在边界重新引入残留；其生命周期由 300s 修剪与 pane 目录销毁负责。
_clear_pending() {
    [ -n "$TMUX_PANE" ] || return
    _acquire_lock || return
    rm -f "$(_pending_pre_path)" "$(_pending_perm_path)" 2>/dev/null
    _release_lock
}

# pending 集合中是否有 N 秒内的条目。用于区分「工具确实在跑」与「泄漏/中断残留
# 的旧条目」——并发 hook 抢锁超时会让 _remove_pending_id 静默放弃，集合可能长期
# 残留陈旧 id（实测存在），不能只按非空判定活跃。
# 时间戳取末列：pending-pre 是 "id tool ts"（3 列），pending-perm 是
# "id mark tool ts"（4 列）——固定 $3 对 perm 永远不命中（历史 bug）。
_pending_recent() {  # $1=秒数 → 0=有新鲜条目
    local max="${1:-10}" now f
    now=$(date +%s)
    for f in "$(_pending_pre_path)" "$(_pending_perm_path)"; do
        [ -s "$f" ] || continue
        if awk -v now="$now" -v max="$max" '
            $NF ~ /^[0-9]+$/ && now - $NF <= max { found = 1; exit }
            END { exit !found }' "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# 根据当前 pending-perm / pending-pre 派生 STATUS。结果写入全局 DERIVED
# return 0 = 派生出非空 STATUS, return 1 = 都空（事件需自行决定）
_derive_status_from_pending() {
    DERIVED=""
    [ -n "$TMUX_PANE" ] || return 1
    local perm; perm=$(_pending_perm_path)
    local pre; pre=$(_pending_pre_path)
    if [ -s "$perm" ]; then
        if awk '{if ($2=="!") {f=1; exit}} END{exit !f}' "$perm" 2>/dev/null; then
            DERIVED="!"; return 0
        fi
        if awk '{if ($2=="?") {f=1; exit}} END{exit !f}' "$perm" 2>/dev/null; then
            DERIVED="?"; return 0
        fi
    fi
    if [ -s "$pre" ]; then
        DERIVED=">"; return 0
    fi
    return 1
}

# 兼容旧调用名（Stop/SessionEnd 仍可能引用）
_clear_all_state() {
    _clear_pending
}

# --- SessionEnd 竞态保护 ---
# /new 触发时 SessionEnd(async) 和 SessionStart(async) 同时执行，
# SessionEnd 可能晚于 SessionStart 写入，将 "-" 覆盖为 ""。
# 清除自身 pane-id 文件后，检查是否有其他 session 已接管此 pane。
_new_session_owns_pane() {
    [ -z "$TMUX_PANE" ] && return 1
    local sanitized; sanitized=$(_pane_sanitized)
    local pane_dir="${_STATUS_DIR}/${sanitized}"
    [ -d "$pane_dir" ] || return 1
    local f
    for f in "${pane_dir}"/pane-*; do
        [ -f "$f" ] || continue
        local stored_pane
        stored_pane=$(cat "$f" 2>/dev/null)
        [ "$stored_pane" = "$TMUX_PANE" ] || continue
        local mtime
        # stat 失败时保守视为新鲜（date +%s），避免误清活跃会话
        mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || date +%s)
        local age=$(( $(date +%s) - mtime ))
        [ "$age" -ge 300 ] && ! _pane_has_ai_process "$TMUX_PANE" && continue
        return 0
    done
    return 1
}

# --- 进程树检查 ---
# BFS 遍历 pane 的进程树，检查是否有 AI CLI 进程。
# 进程名集合从所有 adapter 的 ADAPTER_PROCESS_NAMES 汇总（_collect_ai_process_names），
# 前缀匹配（codex 二进制常为 codex-aarch64-* 等带后缀名）。
# $1=basename 命令 $2=工具进程名（如 codex/opencode）→ 是否前缀匹配
_is_tool_process_name() {
    case "${1:-}" in
        "$2"|"$2"-*|"$2"_*) return 0 ;;
    esac
    return 1
}

_pane_current_command() {  # $1=pane_id → 前台命令
    local pane_id="$1"
    tmux list-panes -a -F "#{pane_id}|#{pane_current_command}" 2>/dev/null \
        | awk -F'|' -v id="$pane_id" '$1==id{print $2; exit}'
}

_pane_command_is_tool() {  # $1=pane_id $2=工具名
    local current_command
    current_command=$(_pane_current_command "$1")
    [ -n "$current_command" ] || return 1
    _is_tool_process_name "$(basename "$current_command" 2>/dev/null)" "$2"
}

# 全量进程快照（一次 ps）：每行 "pid ppid comm"。供多次进程树 BFS 复用。
# 旧的逐 pid `ps -o comm=` + `pgrep -P` 实现在 pane 多的 tick 内会放大到秒级
# （monitor 每 tick 要对每个 launcher pane × 每个工具做一次），改为一次快照 + 内存 BFS。
_ps_process_snapshot() {
    ps -axo pid=,ppid=,comm= 2>/dev/null
}

# 从给定 pid 出发 BFS，匹配进程名集合（空格分隔，前缀匹配）。
# 名称前缀匹配语义同 _is_tool_process_name（codex 匹配 codex-aarch64-*）。
_pid_tree_has_names() {  # $1=pane_pid $2=names [$3=进程快照]
    local pane_pid="$1" names="$2" snapshot="${3:-}"
    [ -n "$pane_pid" ] || return 1
    [ -n "$snapshot" ] || snapshot=$(_ps_process_snapshot)
    [ -n "$snapshot" ] || return 1
    printf '%s\n' "$snapshot" | awk -v root="$pane_pid" -v names="$names" '
        { cmd[$1] = $3; if ($2 != "") children[$2] = children[$2] " " $1 }
        END {
            n = split(names, want, " ")
            frontier = root
            depth = 0
            while (frontier != "" && depth < 10) {
                m = split(frontier, pids, " ")
                nxt = ""
                for (i = 1; i <= m; i++) {
                    base = cmd[pids[i]]
                    sub(/.*\//, "", base)
                    for (j = 1; j <= n; j++) {
                        nm = want[j]
                        if (base == nm \
                            || substr(base, 1, length(nm) + 1) == nm "-" \
                            || substr(base, 1, length(nm) + 1) == nm "_") exit 0
                    }
                    c = split(children[pids[i]], kids, " ")
                    for (k = 1; k <= c; k++) {
                        if (kids[k] == "") continue
                        nxt = nxt (nxt == "" ? "" : " ") kids[k]
                    }
                }
                frontier = nxt
                depth++
            }
            exit 1
        }'
}

# 批量版：一次快照 + 一次 awk，判定每个 root × 每个 name。
# 输出命中行 "<pid><TAB><name>"；monitor 用它把多个 pane 的存活探测合并成一次
# awk（逐 pane 调用 _pid_tree_has_names 会重复解析同一份快照）。
_pid_trees_hits() {  # $1=起点 pid 列表 $2=进程名列表 [$3=进程快照]
    local roots="$1" names="$2" snapshot="${3:-}"
    [ -n "$roots" ] && [ -n "$names" ] || return 0
    [ -n "$snapshot" ] || snapshot=$(_ps_process_snapshot)
    [ -n "$snapshot" ] || return 0
    printf '%s\n' "$snapshot" | awk -v roots="$roots" -v names="$names" '
        { cmd[$1] = $3; if ($2 != "") children[$2] = children[$2] " " $1 }
        END {
            nr = split(roots, r, " ")
            nn = split(names, n, " ")
            for (i = 1; i <= nr; i++)
                for (j = 1; j <= nn; j++)
                    if (_tree_has(r[i], n[j])) print r[i] "\t" n[j]
        }
        function _tree_has(root, want,    frontier, nxt, depth, m, pids, i, k, base, c, kids) {
            frontier = root
            depth = 0
            while (frontier != "" && depth < 10) {
                m = split(frontier, pids, " ")
                nxt = ""
                for (i = 1; i <= m; i++) {
                    base = cmd[pids[i]]
                    sub(/.*\//, "", base)
                    if (base == want \
                        || substr(base, 1, length(want) + 1) == want "-" \
                        || substr(base, 1, length(want) + 1) == want "_") return 1
                    c = split(children[pids[i]], kids, " ")
                    for (k = 1; k <= c; k++) {
                        if (kids[k] == "") continue
                        nxt = nxt (nxt == "" ? "" : " ") kids[k]
                    }
                }
                frontier = nxt
                depth++
            }
            return 0
        }'
}

# BFS pane 进程树，匹配给定进程名集合（空格分隔，前缀匹配）。
_pane_has_process_names() {  # $1=pane_id $2=names [$3=进程快照]
    local pane_id="$1" pane_pid
    # 注意：list-panes -t "%N" 会返回该 pane 所在 window 的全部 pane，
    # 直接取 #{pane_pid} 会混入同 window 其他 pane 的 pid，导致 BFS 爬到
    # 邻近 pane 的 AI 进程而误判。必须用 -a 全局列 + 精确匹配 pane_id。
    pane_pid=$(tmux list-panes -a -F "#{pane_id} #{pane_pid}" 2>/dev/null \
        | awk -v id="$pane_id" '$1==id{print $2; exit}')
    [ -z "$pane_pid" ] && return 1
    _pid_tree_has_names "$pane_pid" "$2" "${3:-}"
}

# 判定 pane 进程树内是否仍有该工具进程（前台命令优先，再 BFS 遍历进程树）
_pane_has_tool_process() {  # $1=pane_id $2=工具名 [$3=进程快照]
    _pane_command_is_tool "$1" "$2" && return 0
    _pane_has_process_names "$1" "$2" "${3:-}"
}

# 所有 adapter 汇总的 AI 进程名
# $2 可选进程快照：调用方批量场景（_cleanup_stale_panes）传入以共用一次 ps
_pane_has_ai_process() {  # $1=pane_id [$2=进程快照]
    _pane_has_process_names "$1" "$(_collect_ai_process_names)" "${2:-}"
}

# 检查 pane 的所有 pane-id 文件是否过期（> 5 min），再验证进程树
# $2 可选进程快照（批量调用方传入，避免逐 pane 一次 ps）
_is_pane_session_dead() {
    local pane_id="$1" snapshot="${2:-}"
    local sanitized="${pane_id//[^a-zA-Z0-9]/_}"
    local pane_dir="${_STATUS_DIR}/${sanitized}"
    [ -d "$pane_dir" ] || return 0
    local f
    for f in "${pane_dir}"/pane-*; do
        [ -f "$f" ] || continue
        local mtime
        # stat 失败时保守视为新鲜（date +%s），避免误清活跃会话
        mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || date +%s)
        local age=$(( $(date +%s) - mtime ))
        [ "$age" -lt 300 ] && return 1
    done
    ! _pane_has_ai_process "$pane_id" "$snapshot"
}

# --- 孤儿状态清理（_refresh 用）---
# 活跃状态 (!, ?, >) 的 pane 必须有对应的 pane 目录和 pane-${SESSION_ID} 文件（由 SessionStart 写入）。
# 无对应文件则说明状态已过期（手动测试残留、pane 被销毁等），清除整个 pane 目录。
# 有对应文件但文件过期且进程已死（Stop 未触发的崩溃场景），也清除。
_cleanup_stale_panes() {
    local active_panes=""
    local f pane_id pane_status pane_dir pid pid_file
    for f in "${_STATUS_DIR}"/*/pane-*; do
        [ -f "$f" ] || continue
        pane_id=$(cat "$f" 2>/dev/null)
        [ -n "$pane_id" ] && active_panes="$active_panes $pane_id"
    done

    # 进程快照取一次循环共用：✓/- 分支与死会话判定逐 pane 调 _pane_has_ai_process
    # 时，旧实现每个 pane 各起一次 ps（pane 多时放大明显）
    local ps_snap
    ps_snap=$(_ps_process_snapshot)

    # 动态追加 monitor seen 字段（与 build_all_status 同一组名字，复用其收集器）。
    # launcher/daemon 场景工具进程可能脱离 pane 进程树，进程树 BFS 看不到；
    # seen=1 是 monitor 用 launcher 进程树探测得出的「工具确实存活」信号。
    local seen_fmt="" _seen_name
    for _seen_name in $(_collect_ai_process_names); do
        seen_fmt="${seen_fmt}|#{@ai_monitor_seen_${_seen_name}}"
    done

    while IFS='|' read -r pane_id pane_status _seen_flags; do
        case "$pane_status" in
            "!"|"?"|">")
                local sanitized="${pane_id//[^a-zA-Z0-9]/_}"
                local pane_dir="${_STATUS_DIR}/${sanitized}"
                if ! echo " $active_panes " | grep -q " $pane_id "; then
                    # 审批态（!/?）有 pending 证据且工具进程仍存活/被 monitor 见过：
                    # 不能因为 pane 映射缺失就清掉「正在等用户」的状态。
                    if { [ "$pane_status" = "!" ] || [ "$pane_status" = "?" ]; } \
                       && _has_pending_approval_evidence "$pane_status" "$pane_id" \
                       && { _pane_has_ai_process "$pane_id" "$ps_snap" \
                            || case "$_seen_flags" in *1*) true ;; *) false ;; esac; }; then
                        _ai_log "STALE: preserved '$pane_status' on $pane_id (evidence=$EVIDENCE_SRC, no pane mapping)"
                        continue
                    fi
                    _ai_log "STALE: clearing orphaned '$pane_status' on $pane_id"
                    tmux set-option -pt "$pane_id" @ai_pane_status "" 2>/dev/null || true
                    rm -rf "$pane_dir" 2>/dev/null
                elif _is_pane_session_dead "$pane_id" "$ps_snap"; then
                    _ai_log "STALE: clearing dead session '$pane_status' on $pane_id"
                    tmux set-option -pt "$pane_id" @ai_pane_status "" 2>/dev/null || true
                    rm -rf "$pane_dir" 2>/dev/null
                fi
                ;;
            "✓"|"-")
                # 终态只认「进程存活」证据：seen=1 时保留（launcher/daemon 场景
                # 进程树不可见）；活跃态 !/?/> 的判据是归属证据，不使用 seen。
                case "$_seen_flags" in
                    *1*) ;;
                    *)
                        if ! _pane_has_ai_process "$pane_id" "$ps_snap"; then
                            _ai_log "STALE: clearing terminal state '$pane_status' on $pane_id (no ai process)"
                            tmux set-option -pt "$pane_id" @ai_pane_status "" 2>/dev/null || true
                        fi
                        ;;
                esac
                ;;
        esac
    done < <(tmux list-panes -a -F "#{pane_id}|#{@ai_pane_status}${seen_fmt}" 2>/dev/null)

    # 清理孤儿目录：目录存在但对应 pane 已不在 tmux 中
    local all_pane_ids
    all_pane_ids=$(tmux list-panes -a -F "#{pane_id}" 2>/dev/null)
    for pane_dir in "${_STATUS_DIR}"/*/; do
        [ -d "$pane_dir" ] || continue
        local dir_name
        dir_name=$(basename "$pane_dir")
        local found=0
        while IFS= read -r pid; do
            [ "${pid//[^a-zA-Z0-9]/_}" = "$dir_name" ] && { found=1; break; }
        done <<< "$all_pane_ids"
        if [ "$found" -eq 0 ]; then
            # 清理孤儿 poll 进程
            for pid_file in "${pane_dir}"*-poll-pid; do
                [ -f "$pid_file" ] || continue
                pid=$(cat "$pid_file" 2>/dev/null)
                [ -n "$pid" ] && kill "$pid" 2>/dev/null
            done
            _ai_log "ORPHAN: removing $pane_dir (pane no longer exists)"
            rm -rf "$pane_dir" 2>/dev/null
        fi
    done
}

# 清理已断开 client 的 @ai_prev_sess_* 残留。key 是写入端有损 sanitize
# （tr -c 'A-Za-z0-9._-' '_'），无法从 key 反推 client → 反向枚举存活集比对。
# 实测关注：长期运行的 server 会累积已 detach 的 client 键（8 option / 4 存活）。
_prune_prev_sess_options() {
    local alive=" " name key opt clients opts
    # 两次 tmux 查询都必须成功才剪枝：tmux 抖动（server 重启/连接失败）时
    # list-clients 返回空会被误判为「无存活 client」→ 把全部键删光。
    clients=$(tmux list-clients -F '#{client_name}' 2>/dev/null) || return 0
    opts=$(tmux show-options -g 2>/dev/null) || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        key=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
        alive="$alive$key "
    done <<< "$clients"
    for opt in $(printf '%s\n' "$opts" | awk '/^@ai_prev_sess_/{print $1}'); do
        key="${opt#@ai_prev_sess_}"
        case "$alive" in
            *" $key "*) ;;
            *) tmux set-option -gu "$opt" 2>/dev/null || true ;;
        esac
    done
}

# 频率限制的孤儿清理（每次 hook 调用，最多每 60s 执行一次）
_maybe_cleanup_stale() {
    local marker="${_STATUS_DIR}/.stale-cleanup-ts"
    local now
    now=$(date +%s)
    [ -d "$_STATUS_DIR" ] || mkdir -p "$_STATUS_DIR" 2>/dev/null
    if [ -f "$marker" ]; then
        local last
        last=$(cat "$marker" 2>/dev/null)
        [ $((now - ${last:-0})) -lt 60 ] && return
    fi
    _cleanup_stale_panes
    _prune_prev_sess_options
    echo "$now" > "$marker"
}

# Hooks 完整性检查：委托给当前 adapter（adapter_check_integrity）。
# 各工具的路径/格式/事件数判定在 adapters/<tool>.sh 中声明，核心不再 case 分派。
# 缺失 → 返回 1（配置被外部应用覆盖时会发生）。
_check_hooks_integrity() {
    if declare -f adapter_check_integrity >/dev/null 2>&1; then
        adapter_check_integrity
    else
        # adapter 未加载（异常）→ 保守视为完整，避免误触发重装
        return 0
    fi
}

# 兜底自修复：tmux 端事件路径与 SessionStart hook 共用，配置被外部覆盖时自动重装。
# 不依赖 SESSION_ID/EVENT，可被 _refresh 与 SessionStart 触发。60s 节流退避
# （窗口内不重复 integrity 检查；修复失败 60s 后才重试）。
# 安装器由 adapter 声明（ADAPTER_INSTALLER）。
_maybe_repair_hooks() {
    # 用户显式卸载意图（suppressed-<tool>）→ 不自动修复，尊重到显式安装为止。
    if [ -f "${_SUPPRESS_DIR}/suppressed-${TOOL_ID:-claude}" ]; then
        _ai_log "REPAIR: suppressed by uninstall marker, skip (${TOOL_ID:-claude})"
        return 0
    fi
    local marker="${_STATUS_DIR}/.hooks-repair-${TOOL_ID:-claude}-ts"
    local now
    now=$(date +%s)
    [ -d "$_STATUS_DIR" ] || mkdir -p "$_STATUS_DIR" 2>/dev/null
    if [ -f "$marker" ]; then
        local last
        last=$(cat "$marker" 2>/dev/null)
        [ $((now - ${last:-0})) -lt 60 ] && return
    fi
    echo "$now" > "$marker"
    local installer="${ADAPTER_INSTALLER}"
    if ! _check_hooks_integrity; then
        _ai_log "REPAIR: hooks integrity check failed, reinstalling (${TOOL_ID:-claude})"
        # 浮出提示（成败区分）：SessionStart（Claude Code hook 进程内）与
        # _run_refresh（tmux run-shell）两个上下文都会到这里；hook 进程继承
        # TMUX env，display-message 无 -p 写 client tty 而非调用方 stdout。
        if [ -x "$installer" ] && "$installer" >/dev/null 2>&1; then
            tmux display-message "✓ ${TOOL_ID:-claude} hooks 已自动修复（检测到缺失）" 2>/dev/null || true
        else
            tmux display-message "⚠ ${TOOL_ID:-claude} hooks 自动修复失败，请运行 tmuxclihook 检查" 2>/dev/null || true
        fi
    fi
}

# 跨工具自修复：tmux 入口所有 _refresh/_session-switched 固定传 TOOL_ID=claude，
# codex/opencode 只有自身 SessionStart 能触发修复；hooks 文件被整体覆盖/删除后
# 再无事件 → 永不自愈。本函数由 _run_refresh 调用，遍历其余 adapter，对
# 「用户显式装过」（installed-<tool> 标记）的工具做 check → 缺失则 install。
#
# 不 source adapter：ADAPTER_* 与 adapter_* 会覆盖当前已加载的 adapter（TOOL_ID
# 污染），一律子进程 exec wrapper（wrapper 自带 _LIB_DIR 与 adapter 加载）。
# 未登记的工具只做「既存安装登记」：check 通过才补写标记，绝不自动安装——
# 尊重 codex/opencode 非人人安装的现状。
# 成本：每工具每 60s 至多 1 次 check；installed 存在且缺失时再加 1 次 install。
_maybe_repair_other_tools() {
    local current="${TOOL_ID:-claude}"
    local f tool installer marker now last
    for f in "${_ADAPTER_DIR}"/*.sh; do
        [ -f "$f" ] || continue
        tool=$(basename "$f" .sh)
        [ "$tool" = "$current" ] && continue
        [ -f "${_SUPPRESS_DIR}/suppressed-${tool}" ] && continue
        installer="${_LIB_DIR}/install-${tool}-hooks.sh"
        [ -x "$installer" ] || continue
        marker="${_STATUS_DIR}/.hooks-repair-${tool}-ts"
        now=$(date +%s)
        [ -d "$_STATUS_DIR" ] || mkdir -p "$_STATUS_DIR" 2>/dev/null
        if [ -f "$marker" ]; then
            last=$(cat "$marker" 2>/dev/null)
            [ $((now - ${last:-0})) -lt 60 ] && continue
        fi
        echo "$now" > "$marker" 2>/dev/null || true
        if [ -f "$(_installed_marker_path "$tool")" ]; then
            "$installer" check >/dev/null 2>&1 && continue
            _ai_log "REPAIR: ${tool} hooks missing, reinstalling (cross-tool)"
            if "$installer" >/dev/null 2>&1; then
                tmux display-message "✓ ${tool} hooks 已自动修复（检测到缺失）" 2>/dev/null || true
            else
                tmux display-message "⚠ ${tool} hooks 自动修复失败，请运行 tmuxclihook 检查" 2>/dev/null || true
            fi
        elif "$installer" check >/dev/null 2>&1; then
            # 未登记但健康：登记既存安装（老用户升级迁移），绝不安装
            _installed_marker_write "$tool" 2>/dev/null || true
            _ai_log "REPAIR: ${tool} hooks healthy, registered installed marker"
        fi
    done
}
