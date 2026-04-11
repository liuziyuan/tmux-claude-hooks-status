# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A tmux plugin that displays Claude Code status in the tmux status bar and pane borders. It hooks into Claude Code's hook system to show real-time state (idle, processing, waiting for authorization, notifications) per pane.

## Architecture

**TPM Plugin** (`tmux-claude-hooks-status.tmux`) — entry point. Runs at tmux startup. Configures pane-border-format with Claude status, binds keyboard shortcuts (`prefix+C-h` install, `prefix+C-u` uninstall).

**Hook Script** (`scripts/tmux-powerline-claude-status`) — the core. Called by Claude Code hooks on each event. Resolves `TMUX_PANE` via process tree walk (hooks don't inherit it), writes per-pane status (`@claude_pane_status`) and aggregated status (`@claude_all_status`) to tmux user options. Spawns a background watcher process that detects idle state when pane title stops changing for 3 seconds.

**Status Renderer** (`scripts/tmux-native-claude-status`) — reads `@claude_all_status` and renders status-right with Claude status + time.

**Hook Installer** (`scripts/install-hooks.sh`) — idempotently registers/unregisters Claude Code hooks in `~/.claude/settings.json` for 10 event types. Uses `jq` for JSON manipulation.

## Status Flow

1. Claude Code fires event → hook script receives event type + JSON on stdin
2. Script maps event to status text (e.g., `⠿ 处理中`, `✓ 空闲`, `🔒 等待授权`)
3. Writes to tmux options: `@claude_pane_status` (per-pane), `@claude_all_status` (aggregated across all panes)
4. tmux pane-border-format and status-right read these options via `#{}` interpolation

## Development Rules

No special cross-file sync requirements. Powerline support has been removed — only native tmux mode is supported now.

## Key Design Decisions

- **Pane resolution**: Hook subprocesses don't inherit `$TMUX_PANE`, so the script walks the process tree (`ps -o ppid`) to match against `tmux list-panes` output.
- **Watcher process**: For events that indicate activity (PostToolUse, UserPromptSubmit), a background watcher monitors pane title stability. After 3 seconds of no title change, it sets status to idle. PID file at `/tmp/claude-watcher-${TMUX_PANE}.pid`.

## Customization Options (tmux options)

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude_hooks_status_color` | `#F1FA8C` | Status text color |
| `@claude_hooks_idle_icon` | `✓` | Idle indicator |
| `@claude_hooks_busy_icon` | `⠿` | Processing indicator |
| `@claude_hooks_auth_icon` | `🔒` | Authorization indicator |

## Dependencies

- tmux >= 3.1
- jq (for hook installation)

## Testing

Manual testing workflow:

```bash
# Trigger a hook manually
echo '{}' | bash scripts/tmux-powerline-claude-status SessionStart
tmux show-option -g @claude_all_status

# Check pane status
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

# Verify hooks registered
jq '.hooks | keys' ~/.claude/settings.json
```
