# tmux-claude-hooks-status

[中文](README_ZH.md)

A tmux plugin that displays AI CLI (Claude Code / Codex) status in the tmux status bar. It hooks into each tool's hook system to show real-time state (idle, processing, waiting for authorization, awaiting user input) per pane via a dedicated status line. Claude Code and Codex share the same hook semantics (event names, stdin JSON fields), so one core script handles both, keyed by `TOOL_ID` (`claude`/`codex`).

## Prerequisites

The interactive TUI is a Node program and **cannot bootstrap its own runtime**, so a few things must exist *before* you run it:

- **Node.js ≥ 18** — required both to `npm install -g` the TUI and to run it. If Node is missing, install it first (e.g. `brew install node`, or via nvm/nodenv). The TUI cannot install Node for you.
- **Homebrew** (macOS, recommended) — the TUI's environment "Doctor" repairs dependencies *only* through Homebrew. Without Homebrew, Doctor just prints manual suggestions and installs nothing.

The actual runtime dependencies — **tmux ≥ 3.1** and **jq** — can either be installed for you by the Doctor (via Homebrew, after you explicitly select them) or installed by hand:

```bash
# macOS: install everything up front
brew install node tmux jq
```

The Doctor never installs anything silently: it acts only on items you select, only via Homebrew, never installs Homebrew itself, never touches non-Homebrew installations, and never auto-installs or upgrades the AI CLIs (Claude Code / Codex / opencode).

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

Claude Code / Codex hooks are plain shell and need only `bash` + `jq`. The opencode integration is a TypeScript plugin executed by opencode itself, so it needs no extra runtime.

### 2. Get the Plugin

Clone the repository into TPM's plugin directory (both integration methods below assume this exact location, which keeps the example paths in this document valid):

```bash
git clone https://github.com/liuziyuan/tmux-claude-hooks-status.git \
  ~/.tmux/plugins/tmux-claude-hooks-status
```

### 3. Integrate into tmux

Pick **one** of the following.

**Recommended — direct `run-shell` (no TPM required):**

Add a single line to `~/.tmux.conf`:

```tmux
run-shell '~/.tmux/plugins/tmux-claude-hooks-status/tmux-ai-hooks-status.tmux'
```

This is exactly what the interactive TUI writes, and it does not depend on a TPM symlink.

**Alternative — TPM (tmux plugin manager):**

If you already manage plugins with TPM, install TPM (if needed) and declare the plugin with its `owner/repo` form so TPM can fetch it:

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

```tmux
# --- Plugins ---
set -g @plugin 'liuziyuan/tmux-claude-hooks-status'

# TPM init (must be at the end)
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
```

Then press `prefix + I` **once** to let TPM fetch it. Note: after the plugin loads it rebinds `prefix + I` to open this project's TUI installer, so TPM's own `prefix + I` only works before the plugin is active (afterwards, install from TPM's menu directly).

On load the plugin automatically:
- Adds a dedicated line to the multi-line `status-format` for the AI status
- Registers lifecycle hooks (session/client/pane) and a tmux-server monitor
- Does not modify your existing `status-right` setting

### 4. Reload

Start (or restart) tmux, then reload:

```
prefix + r
```

(tmux's default prefix is `Ctrl+b`: press and release the prefix, then press the key. If you remapped your prefix to `Ctrl+a`, use that instead.)

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

### 7. Install opencode Plugin (Optional)

In tmux, press:

```
prefix + C-p
```

Unlike Claude Code and Codex, opencode integrates via a TypeScript **plugin** (not a hooks file). The installer writes `~/.config/opencode/plugins/tmux-ai-status.ts`, which opencode loads and runs itself.

To uninstall:

```
prefix + M-p
```

Manual install:

```bash
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-opencode-hooks.sh
```

## Status Symbols and Events

Each pane's status is rendered as a colored background block. Colors follow a fixed Dracula palette and are not user-configurable at the moment.

| Event | Symbol | Color | Meaning |
|-------|--------|-------|---------|
| `SessionStart` | `-` | Yellow | Session idle |
| `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | `>` | Green | Processing |
| `PermissionRequest` (AskUserQuestion) | `?` | Red | Awaiting user input |
| `PermissionRequest` (other tools) | `!` | Red | Waiting for authorization |
| `Stop` / `StopFailure` | `✓` or `-` | Yellow | Completed, or back to idle |
| `SessionEnd` | (empty) | — | Session ended (Claude Code only) |

- Aggregation priority when several panes/states combine: `!` > `?` > `>` > empty.
- There is **no** auto-timeout. A `!`/`?` set by a permission request stays until the request is resolved or cleared by the next `UserPromptSubmit` / `Stop` / `SessionStart`. Rejecting via `Esc` (intercepted by tmux) resets it to `-`; rejecting via the TUI's "No" option leaves `!` until your next prompt.
- `Notification` events (Claude Code only) are handled internally: `idle_prompt` and `denied` / `cancelled` / `rejected` messages reset to `-`.

## Dependencies

- tmux >= 3.1 (user options, set-hook, multi-line status-format)
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

tmux's default prefix is `Ctrl+b` (press and release, then press the key). If you remapped it to `Ctrl+a`, use that instead.

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
