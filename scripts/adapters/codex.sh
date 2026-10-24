#!/bin/bash
# adapters/codex.sh — Codex CLI 工具适配器（需 codex ≥ 0.144）
#
# 由 lib-tmux-ai-status.sh 在确定 TOOL_ID=codex 后 source。契约见 adapters/claude.sh 头注释。
#
# ⚠️ Codex 0.144 与 Claude 的关键差异（本 adapter 声明的语义）：
#   - 无 SessionEnd 事件：codex 退出无任何 hook，pane 内 shell 仍活时 pane-exited 也不触发。
#     退出状态由 tmux-ai-monitor 跟踪已见 Codex 的 pane，进程消失后精确清除。
#   - SessionStart 延迟：codex 的 SessionStart hook 延迟到首个 turn 才发（上游
#     run_pending_session_start_hooks），空闲蹲提示符时无事件。空窗期靠 build_all_status
#     用 pane_current_command 补 idle `-`。
#   - hook trust 门禁：user 来源 hook 需 hooks.state.<key>.trusted_hash 匹配才运行；
#     hash 无法在 bash 复现，靠用户首启 codex TUI 点 "Trust all and continue"。

# Codex 只触发 6 个事件（无 SessionEnd/Notification/PostToolUseFailure/StopFailure）。
ADAPTER_EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop"

# 前台进程名（macOS 上 codex 二进制常为 codex-aarch64-* 等，basename 前缀匹配见
# _pane_has_ai_process 的 case codex*)）
ADAPTER_PROCESS_NAMES="codex"

# hooks 配置：~/.codex/hooks.json（CODEX_HOME 可覆盖）
ADAPTER_HOOKS_FILE="${CODEX_HOME:-$HOME/.codex}/hooks.json"

# Codex 无 SessionEnd → 退出由 tmux-ai-monitor 做进程检测
ADAPTER_HAS_SESSION_END="false"
# SessionStart 延迟到首个 turn
ADAPTER_SESSION_START_TIMING="deferred"
# PermissionRequest 不含 tool_use_id，而 Codex 支持并行工具。核心会将请求绑定到同工具的
# pending PreToolUse ID；无法绑定时用 sentinel 保持 `!` 到 turn/session 边界。
ADAPTER_HOLD_UNMATCHED_PERMISSION="true"
# Codex 的审批不按 tool_input 哈希绑定（保持同工具 LIFO），避免改变既有语义。
ADAPTER_PERMISSION_HASH_BINDING="false"
# request_permissions 直接弹出 Codex 权限 UI，但上游不会发送 PermissionRequest hook。
# 它仍发送可配对的 PreToolUse/PostToolUse，因此可在 PreToolUse 阶段精确进入审批态。
ADAPTER_PERMISSION_PRE_TOOL_NAMES="request_permissions"

# 自修复/TUI 调用的安装脚本
ADAPTER_INSTALLER="${_LIB_DIR}/install-codex-hooks.sh"

# 本插件条目的唯一 marker（归属判定路径无关：contains 子串匹配）。
# 统一用于 count/integrity/detail/strip——避免历史实现里 strip 用宽串
# `tmux-ai-status`、check 用 `tmux-ai-status codex` 的发散。
_CODEX_MARKER="tmux-ai-status codex"

# 完整性计数：6 个事件中注册了含 _CODEX_MARKER 的 command 的事件数（按事件，
# 非扁平总数——重复+缺失的组合在扁平计数下会假阳性）。
_CODEX_JQ_COUNT='
    .hooks as $h |
    ["SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Stop"]
    | map(select([$h[.][]?.hooks[]?.command // empty] | any(contains($marker))))
    | length
'

# 完整性检查：6 事件计数 + 每个事件至少一条条目的脚本文件存活（test -x）。
# 跨安装源路径无关（contains）；脚本死路径（npm 包卸载/volta 换路径，含部分事件死）
# → missing → install 收敛（no-op 门禁随之放行，接受一次 re-trust 代价换功能恢复）。
adapter_check_integrity() {
    [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
    local n ev p ok_events=""
    n=$(jq --arg marker "$_CODEX_MARKER" "$_CODEX_JQ_COUNT" "$ADAPTER_HOOKS_FILE" 2>/dev/null)
    [ "${n:-0}" -ge 6 ] || return 1
    while IFS=$'\t' read -r ev p; do
        if [ -n "$ev" ] && [ -x "$p" ]; then
            case ",$ok_events," in *",$ev,"*) ;; *) ok_events="$ok_events,$ev" ;; esac
        fi
    done < <(jq -r --arg marker "$_CODEX_MARKER" '.hooks as $h |
        ["SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Stop"] as $events |
        $events[] as $e |
        [$h[$e][]?.hooks[]?.command // empty
         | select(contains($marker)) | split(" ")[0]] as $scripts |
        select(($scripts | length) > 0) |
        $scripts[] | "\($e)\t\(.)"' "$ADAPTER_HOOKS_FILE" 2>/dev/null)
    for ev in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop; do
        case ",$ok_events," in *",$ev,"*) ;; *) return 1 ;; esac
    done
    return 0
}

# Codex 6 事件（全部同步——0.144 静默跳过 async=true 的 hook）
_CODEX_EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop"
_CODEX_LEGACY_TOML="${CODEX_HOME:-$HOME/.codex}/hooks.toml"

# Hook 授信记录（trust 维度，check --json 用）：codex 把 user 来源 hook 的授信写在
# 每个实例 config.toml 的 [hooks.state."<hooks.json 路径>:<下划线事件>:<组>:<hook>"]。
# 只判键是否存在——bash 无法复现 trusted_hash；因此：
#   - 键缺失 = 该 hook 一定不会执行（强信号）
#   - 键存在 ≠ 一定执行（hooks 被改写后旧键仍在、hash 失效，codex 会重新弹 Trust）
# config.toml 不存在 → trusted:null（无法判定）。
_CODEX_TRUST_EVENTS="session_start user_prompt_submit pre_tool_use permission_request post_tool_use stop"

_codex_trust_scan() {  # $1=config.toml $2=hooks.json → 每行 "event<TAB>0|1"
    local cfg="$1" hooks="$2" keys e
    [ -f "$cfg" ] || return 1
    # 只提取键名，绝不读取 trusted_hash 值
    keys=$(sed -n 's/^\[hooks\.state\."\([^"]*\)"\].*/\1/p' "$cfg" 2>/dev/null)
    for e in $_CODEX_TRUST_EVENTS; do
        case "$keys" in
            *"$hooks:$e:"*) printf '%s\t1\n' "$e" ;;
            *) printf '%s\t0\n' "$e" ;;
        esac
    done
}

# 汇总 $HOME/.codex 与所有 cc-switch 实例的授信状态（去重；config.toml 不存在则不收录，
# 当前实例不存在时 trusted:null）。只读。
_codex_trust_json() {
    local cfg hooks rows e mark missing trusted seen=""
    for cfg in "${HOME}/.codex/config.toml" "${HOME}"/.cc-switch/instances/codex/*/config.toml; do
        [ -f "$cfg" ] || continue
        [ "$cfg" = "$seen" ] && continue
        seen="$cfg"
        hooks="$(dirname "$cfg")/hooks.json"
        rows=$(_codex_trust_scan "$cfg" "$hooks" 2>/dev/null) || continue
        missing=""
        while IFS=$'\t' read -r e mark; do
            [ "$mark" = "0" ] && missing="${missing}${missing:+,}$e"
        done <<EOF
$rows
EOF
        if [ -n "$missing" ]; then trusted=0; else trusted=1; fi
        printf '%s\t%s\t%s\t%s\n' "$cfg" "$hooks" "$trusted" "$missing"
    done | jq -R -s --arg cur "${CODEX_HOME:-$HOME/.codex}/config.toml" '
        split("\n") | map(select(length > 0) | split("\t")) as $rows
        | [$rows[] | {configFile: .[0], hooksFile: .[1],
                      trusted: (.[2] == "1"),
                      missingEvents: (if .[3] == "" then [] else (.[3] | split(",")) end)}] as $inst
        | ($inst | map(select(.configFile == $cur)) | first) as $cur_obj
        | {configFile: $cur,
           trusted: (if $cur_obj then $cur_obj.trusted else null end),
           missingEvents: (if $cur_obj then $cur_obj.missingEvents else [] end),
           instances: $inst}'
}

# 明细检查（仅 install wrapper 的 check --json 调用；与 claude adapter 同构）。
# 差异：无 cc-switch 分支（hooks.json 即文件真源，mode 恒 file）、6 事件、
# 匹配串为 "tmux-ai-status codex"。失败输出空 events 降级片段，不 exit 非 0。
adapter_check_detail() {
    local src="$ADAPTER_HOOKS_FILE" pairs rows line ev p a trust_json
    trust_json=$(_codex_trust_json)
    if [ ! -f "$src" ]; then
        printf '{"mode":"file","events":{},"plugin":null,"registeredPaths":[],"trust":%s}\n' "$trust_json"
        return 0
    fi
    pairs=$(jq -r --arg marker "$_CODEX_MARKER" '.hooks as $h |
        ["SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Stop"] as $events |
        $events[] as $e |
        $h[$e][]?.hooks[]?.command // empty |
        select(contains($marker)) | split(" ")[0] | "\($e)\t\(.)"' "$src" 2>/dev/null)
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
    jq -R -s --arg mode "file" --arg events "$_CODEX_EVENTS" --argjson trust "$trust_json" '
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
           registeredPaths: ([.[] | .scriptPaths[]] | unique), trust: $trust}
    ' <<<"$rows"
}

# 可选：TMUX_PANE 无法由祖先链确定时，提示 thread 所在 pane（供核心收窄候选）。
# 参数: $1=session_id $2=hook_cwd；只读、不调用 tmux（复用核心 _PANE_SNAPSHOT）。
# codex 实例配置 terminal_title=["thread"]，pane title 形如 "✳ <thread_name>"；
# ${CODEX_HOME}/session_index.jsonl 每行 {id, thread_name, updated_at}，
# hook 输入的 session_id 与其中的 id 一致。用归一化后的精确标题匹配，
# 不依赖 ✳/spinner 前缀；结果再与进程树候选取交集，降低误配。
_codex_session_index_files() {
    local f seen=""
    if [ -n "${CODEX_HOME:-}" ] && [ -f "${CODEX_HOME}/session_index.jsonl" ]; then
        printf '%s\n' "${CODEX_HOME}/session_index.jsonl"
        seen="${CODEX_HOME}/session_index.jsonl"
    fi
    f="${HOME}/.codex/session_index.jsonl"
    if [ -f "$f" ] && [ "$f" != "$seen" ]; then printf '%s\n' "$f"; fi
    for f in "${HOME}"/.cc-switch/instances/codex/*/session_index.jsonl; do
        [ -f "$f" ] || continue
        [ "$f" = "$seen" ] || printf '%s\n' "$f"
    done
}

adapter_pane_hints() {
    local sid="${1:-}" name="" idx target pane path cmd pid server attached title out=""
    [ -n "$sid" ] || return 1
    while IFS= read -r idx; do
        [ -f "$idx" ] || continue
        name=$(jq -r --arg id "$sid" 'select(.id == $id) | .thread_name // empty' \
            "$idx" 2>/dev/null | tail -n 1)
        [ -n "$name" ] && break
    done < <(_codex_session_index_files)
    [ -n "$name" ] || return 1
    target=$(_normalize_title "$name")
    [ -n "$target" ] || return 1
    [ "$_PANE_SNAPSHOT_OK" = "1" ] || return 1
    while IFS='|' read -r pane path cmd pid server attached title; do
        [ -n "$pane" ] || continue
        [ "$(_normalize_title "$title")" = "$target" ] && out="$out $pane"
    done <<EOF
$_PANE_SNAPSHOT
EOF
    [ -n "$out" ] || return 1
    printf '%s\n' "${out# }" | tr ' ' '\n'
}

# 命令级剥离：逐 hook 删除含 _CODEX_MARKER 的 command（不看 type，缺 type 的
# 本插件条目同样清除）；group 仍有剩余 hook 则保留，空 group/事件删除。
# 与 claude 的 _CLAUDE_JQ_STRIP 同构；防御缺 hooks 键 / null / 非数组的 group。
_codex_strip_managed() {
    jq --arg marker "$_CODEX_MARKER" '
      def trim_group:
        if (.hooks | type) == "array" then
          .hooks |= [ .[] | select(((.command // "") | tostring | contains($marker)) | not) ]
          | select((.hooks | length) > 0)
        else . end;
      def trim_event:
        if type == "array" then [ .[] | trim_group ] else . end;
      if (.hooks | type) == "object" then
        .hooks |= (with_entries(.value |= trim_event) | with_entries(select((.value | length) > 0)))
      else . end
      | if (.hooks | type) == "object" and ((.hooks | length) == 0) then del(.hooks) else . end
    '
}

_codex_read_existing() {
    if [ -f "$ADAPTER_HOOKS_FILE" ] && jq empty "$ADAPTER_HOOKS_FILE" >/dev/null 2>&1; then
        cat "$ADAPTER_HOOKS_FILE"
    else
        echo '{}'
    fi
}

# 安装：改写 hooks.json（剥离旧 managed group 后为每事件追加本插件 group），保留他人 hook。
# no-op if valid：事件齐全且脚本存活时不改写——重写即 trusted_hash 失效（command 路径
# 变化 → codex 启动要重新 Trust all），跨安装源重复安装因此保持既有授信。
# TMUX_AI_FORCE_INSTALL=1 旁路 no-op 门禁（漂移收敛专用：hooks 指向其他安装源但脚本
# 仍存活时 integrity 恒过，普通 install 永远收敛不了；代价由调用方确认 re-trust）。
# 清理旧 hooks.toml（0.144 不再读取）。trust 无法在 bash 复现，靠用户首启 codex TUI 授信。
adapter_install_hooks() {
    _install_require_jq
    mkdir -p "$(dirname "$ADAPTER_HOOKS_FILE")" 2>/dev/null || true
    [ -f "$_CODEX_LEGACY_TOML" ] && rm -f "$_CODEX_LEGACY_TOML" && echo "移除旧 hooks.toml（0.144 不再读取）"
    if adapter_check_integrity && [ -z "${TMUX_AI_FORCE_INSTALL:-}" ]; then
        echo "Codex hooks already installed and valid at $ADAPTER_HOOKS_FILE (no-op, trust preserved)"
        return 0
    fi
    local hook_script="${_LIB_DIR}/tmux-ai-status"
    local new_json
    new_json=$(_codex_read_existing | _codex_strip_managed | jq \
        --arg script "$hook_script" \
        --arg events "$_CODEX_EVENTS" '
          .hooks //= {}
          | reduce ($events | split(" ")[]) as $ev (.;
              .hooks[$ev] = ((.hooks[$ev] // []) + [{
                hooks: [{ type: "command", command: ($script + " codex " + $ev), timeout: 5 }]
              }])
            )
        ')
    _install_atomic_write "$new_json" "$ADAPTER_HOOKS_FILE"
    echo "Codex hooks installed to $ADAPTER_HOOKS_FILE"
    echo "Events: $_CODEX_EVENTS"
    echo ""
    echo "⚠️  下次启动 codex 时 TUI 会提示 \"Hooks need review\"，选择 \"Trust all and continue\" 授信一次即可永久生效。"
}

# 卸载：剥离本插件 group，剩空对象则删文件，否则写回。清理旧 toml。
adapter_uninstall_hooks() {
    _install_require_jq
    [ -f "$_CODEX_LEGACY_TOML" ] && rm -f "$_CODEX_LEGACY_TOML" && echo "移除旧 hooks.toml"
    if [ -f "$ADAPTER_HOOKS_FILE" ]; then
        local stripped
        stripped=$(_codex_read_existing | _codex_strip_managed)
        if [ "$(printf '%s' "$stripped" | jq -c .)" = "{}" ]; then
            # 符号链接（cc-switch 实例共享真源）只删真实目标，保留链接
            _install_remove_target "$ADAPTER_HOOKS_FILE"
            echo "Codex hooks uninstalled (removed empty $ADAPTER_HOOKS_FILE)"
        else
            _install_atomic_write "$stripped" "$ADAPTER_HOOKS_FILE"
            echo "Codex hooks uninstalled from $ADAPTER_HOOKS_FILE (preserved external content)"
        fi
    else
        echo "Codex hooks: nothing to uninstall ($ADAPTER_HOOKS_FILE not found)"
    fi
}
