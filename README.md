# tmux-claude-hooks-status

A tmux plugin that displays Claude Code status in the tmux status bar. It hooks into Claude Code's hook system to show real-time state (idle, processing, waiting for authorization, awaiting user input) per pane via a dedicated status line.

## Quick Start (Auto Install)

To install automatically with Claude Code, run:

```
ai https://raw.githubusercontent.com/liuziyuan/tmux-claude-hooks-status/main/AI_INSTALL.md
```

This will guide you through the installation step by step.

## Manual Installation

### 1. Install Dependencies

```bash
# macOS
brew install tmux jq

# Verify versions (tmux >= 3.1 required)
tmux -V
jq --version
```

### 2. Install TPM (Plugin Manager)

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

### 3. Apply tmux Config

Add the following to `~/.tmux.conf`:

```tmux
# --- Plugins ---
set -g @plugin 'tmux-claude-hooks-status'

# TPM init (must be at the end)
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
```

The plugin automatically:
- Adds a dedicated line in the multi-line status-format for Claude status
- Configures pane border display (pane index + title)
- Does not modify your existing `status-right` setting

### 4. Install Plugins

Start (or restart) tmux, then run:

```
prefix + I
```

(Default prefix is `Ctrl+a`. Press and release, then press uppercase `I`.)

TPM will automatically install all declared plugins. After installation, reload:

```
prefix + r
```

### 5. Install Claude Code Hooks

In tmux, press:

```
prefix + C-h
```

The plugin will register hooks in `~/.claude/settings.json`.

To uninstall hooks:

```
prefix + C-u
```

### Manual Hook Install (Alternative)

```bash
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-hooks.sh
```

## Status Symbols and Events

| Event | Status | Color | Meaning |
|-------|--------|-------|---------|
| `SessionStart` | `-` | Yellow | Session idle |
| `PreToolUse` / `PostToolUse` | `>` | Yellow | Processing |
| `PreToolUse` (AskUserQuestion) | `?` | Yellow | Awaiting user input |
| `PermissionRequest` | `!` | Red | Waiting for authorization |
| `Stop` / `StopFailure` | `✓` or `-` | Yellow | Completed or back to idle |
| `SessionEnd` | (empty) | — | Session ended |

Notification events are handled internally — specific messages (permission-related, cancelled, etc.) are dispatched to the appropriate status rather than displayed directly.

## Customization Options

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude_hooks_status_color` | `#F1FA8C` | Status text color |
| `@claude_hooks_idle_icon` | `✓` | Idle indicator |
| `@claude_hooks_busy_icon` | `⠿` | Processing indicator |
| `@claude_hooks_auth_icon` | `🔒` | Authorization indicator |

## Dependencies

- tmux >= 3.1 (user options, pane-border-status, set-hook, multi-line status-format)
- jq (for hook installation)
- bash >= 4.0

## Verification

```bash
# 1. Trigger a hook manually
echo '{}' | bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/tmux-claude-status SessionStart
tmux show-option -g @claude_all_status

# 2. Check pane status
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

# 3. Verify hooks registered
jq '.hooks | keys' ~/.claude/settings.json

# 4. Reload tmux config
tmux source ~/.tmux.conf
```

## Keyboard Shortcuts

Prefix is `Ctrl+a` (press and release, then press the key).

| Shortcut | Action |
|----------|--------|
| `prefix + C-h` | Install Claude Code hooks |
| `prefix + C-u` | Uninstall Claude Code hooks |
| `prefix + I` | TPM install all plugins |
| `prefix + r` | Reload config |
