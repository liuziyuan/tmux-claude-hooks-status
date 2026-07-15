# tmux-claude-hooks-status

[中文](README_ZH.md)

A tmux plugin that displays AI CLI (Claude Code / Codex) status in the tmux status bar. It hooks into each tool's hook system to show real-time state (idle, processing, waiting for authorization, awaiting user input) per pane via a dedicated status line. Claude Code and Codex share the same hook semantics (event names, stdin JSON fields), so one core script handles both, keyed by `TOOL_ID` (`claude`/`codex`).

## Quick Start (Interactive CLI)

Install the published TUI globally with npm (Node.js 18+ required to run it; the plugin's `scripts/` and tmux entry point are bundled inside the npm package, so no repository checkout is required for this path):

```bash
npm install -g tmuxclihook
tmuxclihook
```

Use the menus to check or repair environment dependencies, install/uninstall/repair Claude Code / Codex / opencode hooks, and integrate the plugin into `~/.tmux.conf` (a `run-shell` line pointing at the globally installed package — no TPM symlink needed). After tmux has loaded the plugin, reopen the same TUI with:

```text
prefix + I
```

`npx tmuxclihook` only runs environment and AI CLI checks reliably: its temporary cache directory is cleaned up after each invocation, so any hooks or tmux integration written during that run would point at a path that no longer exists. Use `npm install -g` for anything persistent.

**Developing locally?** Point the TUI at a repository checkout instead of the bundled copy, either via the "source management" menu or:

```bash
TMUXCLIHOOK_SOURCE=/path/to/your/checkout tmuxclihook
```

Hook installation and tmux integration will then write paths under that checkout, so edits take effect immediately without republishing. Switching the source does not retroactively rewrite already-installed hooks or `.tmux.conf` — rerun "Install hooks" / "tmux integration" after switching.

The environment Doctor can install missing Homebrew formulas and upgrade outdated formulas that are already managed by Homebrew. It never installs Homebrew, never changes unmanaged installations, and does not automatically install or upgrade Claude Code or Codex CLI. Every repair requires selection and is followed by a full re-check.

## Quick Hook Uninstall

Open the TUI with `prefix + I` (or `tmuxclihook` / `npm start` in `installer/`) and choose **Uninstall hooks**. For complete plugin removal, including tmux configuration and the plugin link, see [`AI_UNINSTALL.md`](AI_UNINSTALL.md). The compatibility document is retained for non-interactive and recovery workflows.

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
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-claude-hooks.sh
```

### 6. Install Codex Hooks (Optional)

Requires **codex ≥ v0.144** (`hooks.json` lifecycle hooks and hook trust).

In tmux, press:

```
prefix + M-h
```

The plugin registers 6 synchronous hooks in `~/.codex/hooks.json`: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`.

To uninstall:

```
prefix + M-u
```

Manual install:

```bash
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-codex-hooks.sh
```

> Codex has no `SessionEnd` event and defers `SessionStart` until the first turn. A tmux-server monitor therefore refreshes once per second: a newly opened Codex pane displays `-`, and `/exit` clears the pane status after the Codex process disappears. `/new` intentionally keeps the previous `✓` until the next prompt because the same Codex process remains alive.
>
> The installer only replaces hook groups whose command contains `tmux-ai-status`, preserves all other `hooks.json` content, and may require selecting **Hooks need review → Trust all and continue** on the next Codex launch.

## Status Symbols and Events

| Event | Status | Color | Meaning |
|-------|--------|-------|---------|
| `SessionStart` | `-` | Yellow | Session idle |
| `PreToolUse` / `PostToolUse` | `>` | Yellow | Processing |
| `PermissionRequest` (AskUserQuestion) | `?` | Red | Awaiting user input |
| `PermissionRequest` (other tools) | `!` | Red | Waiting for authorization |
| `Stop` / `StopFailure` | `✓` or `-` | Yellow | Completed or back to idle |
| `SessionEnd` | (empty) | — | Session ended |

- `!` status has a 30-second timeout (configurable via `PERMISSION_TIMEOUT` env var) — auto-resets to `-` if the permission is denied or unresolved
- Notification events are handled internally — `idle_prompt` resets to `-`; `permission_prompt` notifications are handled by the PermissionRequest flow

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
- bash (any version; scripts use no bash-4-only features, macOS built-in 3.2 works. Your interactive shell — zsh/fish/etc. — is irrelevant: hooks run under `#!/bin/bash`, invoked by the AI CLI)
- Node.js >= 18 (only for the interactive installer; the shell hooks do not require Node.js)

## Verification

```bash
# 1. Trigger a hook manually
echo '{}' | bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/tmux-ai-status claude SessionStart
tmux show-option -g @ai_all_status

# 2. Check pane status
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@ai_pane_status}"

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
| `prefix + M-h` | Install Codex hooks |
| `prefix + M-u` | Uninstall Codex hooks |
| `prefix + C-p` | Install opencode plugin |
| `prefix + M-p` | Uninstall opencode plugin |
| `prefix + I` | Open the interactive TUI installer |
| `prefix + r` | Reload config |
