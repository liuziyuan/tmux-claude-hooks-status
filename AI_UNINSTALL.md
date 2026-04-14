# tmux-claude-hooks-status AI Uninstall Script

This file is a step-by-step uninstallation guide designed for AI agents to execute. The AI should run each bash code block in order.

> **Note**: This script only removes runtime state and configuration. The plugin directory is preserved.

---

## Step 0: Locate Plugin Directory

Determine the plugin installation path. It may be a TPM clone or a local development copy.

```bash
# Try TPM path first, then fall back to common locations
if [ -d "$HOME/.tmux/plugins/tmux-claude-hooks-status" ]; then
    PLUGIN_DIR="$HOME/.tmux/plugins/tmux-claude-hooks-status"
elif [ -d "$HOME/work/home/tmux-claude-hooks-status" ]; then
    PLUGIN_DIR="$HOME/work/home/tmux-claude-hooks-status"
else
    echo "[ERROR] Plugin directory not found"
    echo "Searched:"
    echo "  - $HOME/.tmux/plugins/tmux-claude-hooks-status"
    echo "  - $HOME/work/home/tmux-claude-hooks-status"
fi

echo "Plugin dir: ${PLUGIN_DIR:-NOT FOUND}"
```

---

## Step 1: Unregister Claude Code Hooks

Remove all hook entries pointing to this plugin from `~/.claude/settings.json`.

```bash
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

if [ -f "$PLUGIN_DIR/scripts/install-hooks.sh" ]; then
    bash "$PLUGIN_DIR/scripts/install-hooks.sh" uninstall
else
    # Fallback: remove hooks manually via jq
    if command -v jq &>/dev/null && [ -f "$SETTINGS_FILE" ]; then
        HOOK_SCRIPT="$PLUGIN_DIR/scripts/tmux-claude-status"
        for EVENT in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop StopFailure; do
            UPDATED=$(jq --arg event "$EVENT" --arg hook_script "$HOOK_SCRIPT" '
                .hooks[$event] = [
                    .hooks[$event][]?
                    | .hooks = [.hooks[] | select(.command | startswith($hook_script) | not)]
                ] | .hooks[$event] = [.hooks[$event][] | select(.hooks | length > 0)]
            ' "$SETTINGS_FILE")
            echo "$UPDATED" > "$SETTINGS_FILE"
        done
        echo "[OK] Hooks removed manually"
    else
        echo "[WARN] Cannot remove hooks (jq or settings.json not found)"
    fi
fi
```

---

## Step 2: Kill Background Watcher Processes

Terminate any running watcher processes spawned by the plugin.

```bash
KILLED=0
for f in /tmp/claude-watcher-*.pid; do
    [ -f "$f" ] || continue
    PID=$(cat "$f" 2>/dev/null)
    if [ -n "$PID" ] && kill "$PID" 2>/dev/null; then
        echo "[OK] Killed watcher PID $PID"
        KILLED=$((KILLED + 1))
    fi
    rm -f "$f"
done

if [ "$KILLED" -eq 0 ]; then
    echo "[OK] No watcher processes found"
fi

# Clean up temporary protection files (created during permission/question events)
rm -f /tmp/claude-protect-* 2>/dev/null
PROTECT_COUNT=$(ls /tmp/claude-protect-* 2>/dev/null | wc -l)
if [ "$PROTECT_COUNT" -eq 0 ]; then
    echo "[OK] Cleaned temporary protection files"
fi

# Clean up temporary bind configuration files (created during plugin reload)
rm -f /tmp/tmux-claude-bind-*.conf 2>/dev/null
BIND_COUNT=$(ls /tmp/tmux-claude-bind-*.conf 2>/dev/null | wc -l)
if [ "$BIND_COUNT" -eq 0 ]; then
    echo "[OK] Cleaned temporary bind config files"
fi
```

---

## Step 3: Clean tmux Options

Remove all tmux user options and settings set by the plugin. Restore status bar to single line.

```bash
if tmux info &>/dev/null; then
    # Remove plugin-specific user options
    tmux set-option -gu @claude_all_status 2>/dev/null
    tmux set-option -gu @claude_status 2>/dev/null
    tmux set-option -gu @claude_hooks_reload_registered 2>/dev/null
    
    # Remove custom configuration options (set by plugin at startup)
    tmux set-option -gu @claude_hooks_status_color 2>/dev/null
    tmux set-option -gu @claude_hooks_idle_icon 2>/dev/null
    tmux set-option -gu @claude_hooks_busy_icon 2>/dev/null
    tmux set-option -gu @claude_hooks_auth_icon 2>/dev/null

    # Remove Claude status format row — find which row the plugin occupies
    STATUS_VAL=$(tmux show-option -gv status 2>/dev/null || echo "on")
    case "$STATUS_VAL" in
        on|off) CLAUDE_ROW="" ;;
        [0-9]*)
            # status is multi-line, check last row for plugin signature
            LAST_ROW=$((STATUS_VAL - 1))
            LAST_FMT=$(tmux show-option -gv "status-format[${LAST_ROW}]" 2>/dev/null || true)
            if echo "$LAST_FMT" | grep -q "@claude_all_status"; then
                CLAUDE_ROW=$LAST_ROW
            fi
            ;;
    esac

    # Remove the Claude status row and restore single-line status
    if [ -n "$CLAUDE_ROW" ]; then
        tmux set-option -gu "status-format[${CLAUDE_ROW}]" 2>/dev/null
        tmux set-option -g status on 2>/dev/null
        echo "[OK] Removed Claude status row, restored single-line status bar"
    fi

    # Clear per-pane status options
    while IFS= read -r pane_id; do
        tmux set-option -pqt "$pane_id" @claude_pane_status 2>/dev/null
    done < <(tmux list-panes -a -F "#{pane_id}" 2>/dev/null)

    echo "[OK] tmux options cleaned"
else
    echo "[SKIP] No running tmux server"
fi
```

---

## Step 4: Remove Plugin Configuration from ~/.tmux.conf

Remove all lines related to this plugin from `.tmux.conf`.

```bash
TMUX_CONF="$HOME/.tmux.conf"

if [ ! -f "$TMUX_CONF" ]; then
    echo "[SKIP] No .tmux.conf found"
else
    CHANGES=0

    # Remove plugin declaration line: set -g @plugin 'tmux-claude-hooks-status'
    if grep -q "tmux-claude-hooks-status" "$TMUX_CONF"; then
        sed -i '' '/tmux-claude-hooks-status/d' "$TMUX_CONF"
        CHANGES=$((CHANGES + 1))
        echo "[OK] Removed plugin declaration"
    fi

    # Remove pane-border config (if user added from Step 4d of installation)
    # This section removes all 4 lines of pane-border configuration if they exist
    if grep -q "pane-border-status\|pane-border-format\|pane-active-border-style\|pane-border-style" "$TMUX_CONF"; then
        sed -i '' '/^[[:space:]]*set -g pane-border-status\|^[[:space:]]*set -g pane-border-format\|^[[:space:]]*set -g pane-active-border-style\|^[[:space:]]*set -g pane-border-style/d' "$TMUX_CONF"
        CHANGES=$((CHANGES + 1))
        echo "[OK] Removed pane-border configuration"
    fi

    # Remove plugin comment line if it exists (e.g., "# Pane border display")
    if grep -q "# Pane border display" "$TMUX_CONF"; then
        sed -i '' '/# Pane border display/d' "$TMUX_CONF"
        CHANGES=$((CHANGES + 1))
        echo "[OK] Removed pane-border comment"
    fi

    # Clean up consecutive blank lines (max 1 blank line between sections)
    awk 'BEGIN{blank=0} /^[[:space:]]*$/{blank++; if(blank<=1) print; next} {blank=0; print}' "$TMUX_CONF" > "${TMUX_CONF}.tmp" && mv "${TMUX_CONF}.tmp" "$TMUX_CONF"

    if [ "$CHANGES" -eq 0 ]; then
        echo "[OK] No plugin-related lines found in .tmux.conf"
    fi
fi
```

---

## Step 5: Reload tmux Configuration

Apply the cleaned configuration to the running tmux server.

```bash
if tmux info &>/dev/null; then
    tmux source-file ~/.tmux.conf 2>/dev/null && echo "[OK] tmux config reloaded"
else
    echo "[SKIP] No running tmux server, config will take effect on next start"
fi
```

---

## Step 6: Verify Uninstallation

Confirm all plugin traces have been removed.

```bash
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
ERRORS=0

echo ""
echo "========== Uninstallation Verification =========="

# 1. Hooks removed from settings.json
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
    REMAINING=$(jq --arg prefix "$PLUGIN_DIR" '
        [.hooks // {} | to_entries[] | select(.value != null)]
        | map(select(.value | flatten | map(.command // "") | map(startswith($prefix)) | any))
        | length
    ' "$SETTINGS_FILE" 2>/dev/null || echo "0")
    if [ "${REMAINING:-0}" -eq 0 ]; then
        echo "[OK] No plugin hooks remaining in settings.json"
    else
        echo "[FAIL] $REMAINING hook(s) still registered"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "[WARN] Cannot verify hooks (jq or settings.json missing)"
fi

# 2. No watcher processes
WATCHER_COUNT=$(ls /tmp/claude-watcher-*.pid 2>/dev/null | wc -l | tr -d ' ')
if [ "$WATCHER_COUNT" -eq 0 ]; then
    echo "[OK] No watcher processes"
else
    echo "[FAIL] $WATCHER_COUNT watcher PID file(s) remain"
    ERRORS=$((ERRORS + 1))
fi

# 3. tmux user options cleared
if tmux info &>/dev/null; then
    OPT_STATUS=$(tmux show-option -g @claude_all_status 2>/dev/null)
    if [ -z "$OPT_STATUS" ]; then
        echo "[OK] @claude_all_status cleared"
    else
        echo "[FAIL] @claude_all_status still set: $OPT_STATUS"
        ERRORS=$((ERRORS + 1))
    fi

    STATUS_VAL=$(tmux show-option -gv status 2>/dev/null)
    case "$STATUS_VAL" in
        on|1) echo "[OK] Status bar is single-line" ;;
        *)   echo "[WARN] Status bar value: $STATUS_VAL (may need manual fix)" ;;
    esac
else
    echo "[SKIP] No running tmux server"
fi

# 4. .tmux.conf cleaned
TMUX_CONF="$HOME/.tmux.conf"
if [ -f "$TMUX_CONF" ]; then
    if grep -q "tmux-claude-hooks-status\|pane-border-status.*top\|pane-border-format.*@claude" "$TMUX_CONF" 2>/dev/null; then
        echo "[FAIL] Plugin references still in .tmux.conf"
        grep -n "tmux-claude-hooks-status\|pane-border" "$TMUX_CONF"
        ERRORS=$((ERRORS + 1))
    else
        echo "[OK] No plugin references in .tmux.conf"
    fi
fi

# 5. Temporary files cleaned
TEMP_PROTECT=$(ls /tmp/claude-protect-* 2>/dev/null | wc -l | tr -d ' ')
TEMP_BIND=$(ls /tmp/tmux-claude-bind-*.conf 2>/dev/null | wc -l | tr -d ' ')
if [ "$TEMP_PROTECT" -eq 0 ] && [ "$TEMP_BIND" -eq 0 ]; then
    echo "[OK] No temporary plugin files remaining"
else
    echo "[WARN] Some temporary files remain: protect=$TEMP_PROTECT, bind=$TEMP_BIND"
fi

# 6. Custom tmux options cleaned
if tmux info &>/dev/null; then
    CUSTOM_OPTS=""
    [ -n "$(tmux show-option -g @claude_hooks_status_color 2>/dev/null)" ] && CUSTOM_OPTS="@claude_hooks_status_color "
    [ -n "$(tmux show-option -g @claude_hooks_idle_icon 2>/dev/null)" ] && CUSTOM_OPTS="${CUSTOM_OPTS}@claude_hooks_idle_icon "
    [ -n "$(tmux show-option -g @claude_hooks_busy_icon 2>/dev/null)" ] && CUSTOM_OPTS="${CUSTOM_OPTS}@claude_hooks_busy_icon "
    [ -n "$(tmux show-option -g @claude_hooks_auth_icon 2>/dev/null)" ] && CUSTOM_OPTS="${CUSTOM_OPTS}@claude_hooks_auth_icon "
    
    if [ -z "$CUSTOM_OPTS" ]; then
        echo "[OK] No custom tmux options remaining"
    else
        echo "[WARN] Custom options still set: $CUSTOM_OPTS"
    fi
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "========== Uninstallation Successful =========="
else
    echo "========== $ERRORS check(s) failed =========="
    echo "Review the output above and fix manually."
fi
```
