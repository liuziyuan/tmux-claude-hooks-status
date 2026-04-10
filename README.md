# tmux-claude-hooks-status

A tmux plugin that displays Claude Code status in the tmux status bar and pane borders. It hooks into Claude Code's hook system to show real-time state (idle, processing, waiting for authorization, notifications) per pane.

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
set -g @plugin 'erikw/tmux-powerline'
set -g @plugin 'tmux-claude-hooks-status'

# TPM init (must be at the end)
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'

# Claude Code status bar (must be after TPM init)
set -g status-right "#{?#{@claude_all_status},#{@claude_all_status} ,}#(~/.tmux/plugins/tmux-powerline/powerline.sh right)"
set -g status-right-length 120

# Pane border display
set -g pane-border-status top
set -g pane-border-format " #[fg=#BD93F9]#P#[default]#{?#{@claude_pane_status}, #[fg=#F1FA8C]#{@claude_pane_status}#[default],} #{pane_title} "
set -g pane-active-border-style "fg=#BD93F9"
set -g pane-border-style "fg=#6272A4"
```

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

## Plugin Features

| Event | Pane Border Display |
|-------|-------------------|
| `SessionStart` / `Stop` / `StopFailure` | `✓ Idle` |
| `UserPromptSubmit` / `PostToolUse` | `⠿ Processing` |
| `PermissionRequest` | `🔒 Awaiting Auth` |
| `Notification` | `💬 <first 40 chars>` |
| `SessionEnd` | (cleared) |

## Dual Mode Support

The plugin auto-detects the running mode:

- **Powerline mode**: When tmux-powerline is detected, Claude status is prepended before powerline segments in status-right.
- **Native mode**: Without powerline, status-right is rendered independently (Claude status + clock).

Force a specific mode:

```bash
# In .tmux.conf
set -g @claude_hooks_mode "native"     # Force native mode
set -g @claude_hooks_mode "powerline"  # Force powerline mode
```

## Customization Options

| Option | Default | Purpose |
|--------|---------|---------|
| `@claude_hooks_status_color` | `#F1FA8C` | Status text color |
| `@claude_hooks_idle_icon` | `✓` | Idle indicator |
| `@claude_hooks_busy_icon` | `⠿` | Processing indicator |
| `@claude_hooks_auth_icon` | `🔒` | Authorization indicator |
| `@claude_hooks_mode` | `auto` | Force `native` or `powerline` mode |

## Dependencies

- tmux >= 3.1
- jq (for hook installation)

## Verification

```bash
# 1. Trigger a hook manually
echo '{}' | bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/tmux-powerline-claude-status SessionStart
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
