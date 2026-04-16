# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Terminology

**AI Status** — 本项目所实现的核心功能的统称。指通过 tmux 状态栏和窗格边框实时显示 AI 编程助手（如 Claude Code、GitHub Copilot 等）运行状态的能力，包括状态检测、事件监听、符号渲染、颜色编码等整套机制。

## Project Overview

A tmux plugin that displays Claude Code status in the tmux status bar and pane borders. It hooks into Claude Code's hook system to show real-time state (idle, processing, waiting for authorization) per pane via a dedicated status line.

## Architecture

### Core Files

**`tmux-claude-hooks-status.tmux`** (76 lines) — TPM plugin entry point
- Runs at tmux startup and on `prefix+r` reload
- Configures pane-border-format (pane index + title)
- Registers Claude Code events and tmux session/client hooks
- Manages multi-line status format (appends Claude status as independent status-format line)
- Reload protection: overrides `prefix+r` to auto-initialize on reconfig
- Binds keyboard shortcuts: `prefix+C-h` (install), `prefix+C-u` (uninstall)

**`scripts/tmux-claude-status`** (212 lines) — Core event handler
- Invoked by Claude Code on hook events (SessionStart, UserPromptSubmit, PermissionRequest, etc.)
- Resolves `TMUX_PANE` via process tree walk (hooks don't inherit `$TMUX_PANE`)
- Maps Claude Code events to status symbols: `-` (idle), `>` (processing), `?` (user question), `!` (auth waiting)
- Writes per-pane status (`@claude_pane_status`) and aggregated status (`@claude_all_status`)
- Spawns watcher process for permission requests: monitors when user dismisses permission prompt (process exits) and resets status to idle

**`scripts/install-hooks.sh`** (94 lines) — Hook registration
- Idempotently registers/unregisters 10 Claude Code events into `~/.claude/settings.json`
- Uses `jq` for JSON manipulation
- Supports both install and uninstall modes

### Data Flow

```
Claude Code Event (SessionStart, UserPromptSubmit, etc.)
    ↓
tmux-claude-status script
    ├─ Resolve TMUX_PANE (process tree walk)
    ├─ Map event → status symbol
    ├─ Write @claude_pane_status (per-pane)
    ├─ Call build_all_status()
    │  └─ Scan all attached-session panes
    │  └─ Build aggregated @claude_all_status
    ├─ Optionally spawn permission watcher
    └─ Exit

Watcher Process (if permission request)
    ├─ Every 1s: check if Claude process still running
    ├─ If ! overwritten by racing PostToolUse → re-assert ! (within 3s window)
    └─ If exited & status still '!': reset to '-' + rebuild

Race Protection (timestamp-based)
    ├─ _set_protection: record timestamp when ! or ? is set
    ├─ _is_protected: check if timestamp is within 3s window
    ├─ PostToolUse: skip if current status is !/? AND _is_protected
    └─ Watcher: re-assert ! if overwritten by > within protection window

tmux session/client lifecycle hooks
    (session-closed, client-detached, client-attached)
    ↓
    Trigger _refresh pseudo-event
    ↓
    Rebuild @claude_all_status (only attached sessions)
```

## Status Symbols and Events

| Event | Status | Color | Meaning |
|-------|--------|-------|---------|
| SessionStart | `-` | Yellow | Session idle |
| PreToolUse / PostToolUse | `>` | Yellow | Processing |
| PreToolUse (AskUserQuestion) | `?` | Yellow | Awaiting user input |
| PermissionRequest | `!` | Red | Waiting for authorization |
| Stop / StopFailure | `✓` or `-` | Yellow | Completed or back to idle |
| SessionEnd | `` (empty) | — | Session ended |
| _refresh (internal) | (rebuilt) | — | Aggregated state refresh |

## Development Workflow

### Local Setup

1. Clone/symlink plugin to tmux plugin directory:
   ```bash
   ln -s /Users/liuziyuan/work/home/tmux-claude-hooks-status ~/.tmux/plugins/tmux-claude-hooks-status
   ```

2. Install Claude Code hooks (one-time):
   ```bash
   prefix + C-h
   # Or manually: bash scripts/install-hooks.sh
   ```

3. Test changes immediately with `prefix+r` (reload plugin entry point automatically)

### Testing Commands

```bash
# Manually trigger a hook event
echo '{}' | bash scripts/tmux-claude-status SessionStart
tmux show-option -g @claude_all_status

# Check all pane statuses
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

# Verify hooks registered in Claude Code
jq '.hooks | keys' ~/.claude/settings.json

# Trigger permission request simulation
echo '{}' | bash scripts/tmux-claude-status PermissionRequest
# Should show '!' (red) temporarily, auto-reset to '-' after 3s

# Watch watcher process
ps aux | grep "claude-watcher"

# Reload tmux config
tmux source ~/.tmux.conf
```

### Common Development Tasks

**Modify status symbol mapping**: Edit the `case "$EVENT"` block in `scripts/tmux-claude-status` (around line 119).

**Add new Claude Code event**: 
1. Add event name to `EVENTS` array in `scripts/install-hooks.sh`
2. Add event handler in `scripts/tmux-claude-status` case statement
3. Reload: `prefix+r` to test

**Change display format**: Edit `build_all_status()` function in `scripts/tmux-claude-status` (around line 12) or status-format line in `tmux-claude-hooks-status.tmux` (line 41).

**Customize colors/icons**: Add to `~/.tmux.conf`:
```bash
set -g @claude_hooks_status_color '#FF6B6B'
set -g @claude_hooks_idle_icon '✔'
set -g @claude_hooks_busy_icon '◄▶'
set -g @claude_hooks_auth_icon '⚠'
```

## Key Design Decisions

- **Attached-only display**: `build_all_status()` filters `session_attached==1` to exclude detached sessions from aggregated view
- **Process tree resolution**: Since hook subprocesses don't inherit `TMUX_PANE`, walk process parents (`ps -o ppid`) to find the pane PID
- **Watcher as separate process**: Permission state monitoring uses background process + PID file (`/tmp/claude-watcher-${TMUX_PANE}.pid`) with generation ID to prevent race conditions
- **Timestamp-based race protection**: When `!` or `?` is set, a 3-second protection window is recorded (`/tmp/claude-protect-${TMUX_PANE}`). Async `PostToolUse` events from previous tools are blocked during this window. The watcher also re-asserts `!` if a racing event overwrites it
- **Idempotent initialization**: Plugin can be reloaded via `prefix+r` without side effects (checks if line already occupied, register hooks only if missing)
- **Stale hook cleanup**: `install-hooks.sh` removes dead hooks (non-existent script paths) and duplicate plugin-path hooks before installing
- **Multi-line status**: Claude status occupies independent `status-format[N]` line, preserving user's `status-right` configuration

## Customization Options

| tmux Option | Default | Purpose |
|-----------|---------|---------|
| `@claude_hooks_status_color` | `#F1FA8C` | Status text color |
| `@claude_hooks_idle_icon` | `✓` | Idle indicator |
| `@claude_hooks_busy_icon` | `⠿` | Processing indicator |
| `@claude_hooks_auth_icon` | `🔒` | Authorization indicator |

## Dependencies

- tmux >= 3.1 (supports user options, pane-border-status, set-hook, multi-line status-format)
- jq (JSON manipulation)
- bash >= 4.0 (process substitution, arrays)

## Hook Events Registered

The plugin registers Claude Code hooks for these 10 events (in `install-hooks.sh`):

1. SessionStart — Session initialized
2. SessionEnd — Session ended
3. UserPromptSubmit — User submitted input
4. PreToolUse — Before tool execution
5. PostToolUse — After successful tool execution
6. PostToolUseFailure — Tool execution failed
7. PermissionRequest — Awaiting user authorization
8. Notification — Generic notification
9. Stop — Session stopped
10. StopFailure — Stop failed

All registered to `~/.claude/settings.json` with async=true except PermissionRequest (async=false for immediate blocking).
