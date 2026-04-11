# tmux-claude-hooks-status AI Install Script

This file is a step-by-step installation guide designed for AI agents to execute. The AI should run each bash code block in order.

> **Prerequisite**: macOS with Homebrew installed.

---

## Step 0: Check Dependencies

Check if tmux, jq, and git are installed. Missing dependencies will be installed in Step 1.

```bash
ERRORS=0

# Check tmux
if command -v tmux &>/dev/null; then
    TMUX_VERSION=$(tmux -V 2>/dev/null | grep -o '[0-9.]*')
    echo "[OK] tmux $TMUX_VERSION"
else
    echo "[MISSING] tmux not installed"
    ERRORS=$((ERRORS + 1))
fi

# Check jq
if command -v jq &>/dev/null; then
    echo "[OK] jq $(jq --version 2>/dev/null)"
else
    echo "[MISSING] jq not installed"
    ERRORS=$((ERRORS + 1))
fi

# Check git
if command -v git &>/dev/null; then
    echo "[OK] git $(git --version 2>/dev/null | grep -o '[0-9.]*')"
else
    echo "[MISSING] git not installed"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "$ERRORS dependency(ies) missing, will install in Step 2."
else
    echo ""
    echo "All dependencies ready."
fi
```

---

## Step 1: Install Missing Dependencies

Install missing dependencies via Homebrew. `brew install` is idempotent when already installed.

```bash
# Install missing dependencies
PACKAGES=""
command -v tmux &>/dev/null || PACKAGES="$PACKAGES tmux"
command -v jq &>/dev/null || PACKAGES="$PACKAGES jq"
command -v git &>/dev/null || PACKAGES="$PACKAGES git"

if [ -n "$PACKAGES" ]; then
    echo "Installing dependencies:$PACKAGES"
    brew install $PACKAGES
else
    echo "All dependencies installed, skipping."
fi
```

---

## Step 2: Install TPM (Tmux Plugin Manager)

Clone TPM to `~/.tmux/plugins/tpm` if not already installed.

```bash
TPM_DIR="$HOME/.tmux/plugins/tpm"

if [ -d "$TPM_DIR" ]; then
    echo "[OK] TPM already installed at $TPM_DIR"
else
    echo "Installing TPM..."
    mkdir -p "$HOME/.tmux/plugins"
    git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
    echo "[OK] TPM installation complete"
fi
```

---

## Step 3: Install tmux-claude-hooks-status Plugin

Clone the plugin into the TPM plugins directory.

```bash
PLUGIN_DIR="$HOME/.tmux/plugins/tmux-claude-hooks-status"
PLUGIN_REPO="git@github.com:liuziyuan/tmux-claude-hooks-status.git"

if [ -d "$PLUGIN_DIR" ]; then
    echo "[OK] Plugin already installed at $PLUGIN_DIR"
    if [ -L "$PLUGIN_DIR" ]; then
        echo "  (symlink -> $(readlink "$PLUGIN_DIR"))"
    fi
else
    echo "Cloning tmux-claude-hooks-status..."
    git clone "$PLUGIN_REPO" "$PLUGIN_DIR"
    echo "[OK] Plugin cloned"
fi
```

---

## Step 4: Configure .tmux.conf

Safely modify `.tmux.conf`: add plugin declarations and status bar config. Each operation checks for existing entries before modifying.

### 4a: Backup Current Config

```bash
TMUX_CONF="$HOME/.tmux.conf"

if [ -f "$TMUX_CONF" ]; then
    BACKUP="${TMUX_CONF}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$TMUX_CONF" "$BACKUP"
    echo "Backed up: $BACKUP"
else
    # Create minimal config
    cat > "$TMUX_CONF" << 'TMUX_CONF_EOF'
# tmux basic config
set -g prefix C-a
unbind C-b
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
TMUX_CONF_EOF
    echo "Created new .tmux.conf"
fi
```

### 4b: Add Plugin Declarations

```bash
TMUX_CONF="$HOME/.tmux.conf"

# Check if plugin is already declared
if grep -q "tmux-claude-hooks-status" "$TMUX_CONF"; then
    echo "[OK] Plugin declaration already exists in .tmux.conf"
else
    # Insert before TPM init
    if grep -q "set -g @plugin 'tmux-plugins/tpm'" "$TMUX_CONF"; then
        sed -i '' "/set -g @plugin 'tmux-plugins\/tpm'/i\\
set -g @plugin 'tmux-claude-hooks-status'
" "$TMUX_CONF"
        echo "[OK] Added plugin declaration before TPM init"
    else
        # No TPM init found, append
        echo "" >> "$TMUX_CONF"
        echo "# tmux-claude-hooks-status plugin" >> "$TMUX_CONF"
        echo "set -g @plugin 'tmux-claude-hooks-status'" >> "$TMUX_CONF"
        echo "[OK] Appended plugin declaration"
    fi
fi
```

### 4c: Add TPM Init (if missing)

```bash
TMUX_CONF="$HOME/.tmux.conf"

# Ensure TPM init block exists and is at the end
if grep -q "run '~/.tmux/plugins/tpm/tpm'" "$TMUX_CONF"; then
    echo "[OK] TPM init already exists in .tmux.conf"
else
    echo "" >> "$TMUX_CONF"
    echo "# TPM init (must be at the end)" >> "$TMUX_CONF"
    echo "set -g @plugin 'tmux-plugins/tpm'" >> "$TMUX_CONF"
    echo "run '~/.tmux/plugins/tpm/tpm'" >> "$TMUX_CONF"
    echo "[OK] Added TPM init block"
fi
```

### 4d: Add Pane Border Config (must be after TPM init)

**Note**: The plugin does NOT modify `status-right`. Claude status is displayed on a separate row via multi-line `status-format`. The user's existing `status-right` is preserved as-is.

```bash
TMUX_CONF="$HOME/.tmux.conf"

# Ensure pane-border config exists
if grep -q "pane-border-status" "$TMUX_CONF"; then
    echo "[OK] pane-border config already exists"
else
    echo "" >> "$TMUX_CONF"
    echo "# Pane border display" >> "$TMUX_CONF"
    echo 'set -g pane-border-status top' >> "$TMUX_CONF"
    echo 'set -g pane-border-format " #[fg=#BD93F9]#P#[default]#{?#{@claude_pane_status}, #[fg=#F1FA8C]#{@claude_pane_status}#[default],} #{pane_title} "' >> "$TMUX_CONF"
    echo 'set -g pane-active-border-style "fg=#BD93F9"' >> "$TMUX_CONF"
    echo 'set -g pane-border-style "fg=#6272A4"' >> "$TMUX_CONF"
    echo "[OK] Added pane-border config"
fi
```

---

## Step 5: Register Claude Code Hooks

Run the plugin's `install-hooks.sh` to register hooks in `~/.claude/settings.json`. The script is idempotent.

```bash
PLUGIN_DIR="$HOME/.tmux/plugins/tmux-claude-hooks-status"

if [ -f "$PLUGIN_DIR/scripts/install-hooks.sh" ]; then
    bash "$PLUGIN_DIR/scripts/install-hooks.sh"
else
    echo "[ERROR] install-hooks.sh not found: $PLUGIN_DIR/scripts/install-hooks.sh"
    echo "Make sure the plugin is properly installed."
fi
```

---

## Step 6: Reload tmux and Verify

### 6a: Reload Config

```bash
# Reload tmux config
if tmux info &>/dev/null; then
    tmux source-file ~/.tmux.conf 2>/dev/null && echo "[OK] tmux config reloaded"

    # Run plugin entry point to ensure immediate effect
    PLUGIN_DIR="$HOME/.tmux/plugins/tmux-claude-hooks-status"
    if [ -f "$PLUGIN_DIR/tmux-claude-hooks-status.tmux" ]; then
        bash "$PLUGIN_DIR/tmux-claude-hooks-status.tmux" 2>/dev/null && echo "[OK] Plugin initialized"
    fi
else
    echo "[WARN] No tmux server running. Start tmux and run: prefix + I"
fi
```

### 6b: Verify Installation

```bash
PLUGIN_DIR="$HOME/.tmux/plugins/tmux-claude-hooks-status"
SETTINGS_FILE="$HOME/.claude/settings.json"
ERRORS=0

echo ""
echo "========== Installation Verification =========="

# 1. Plugin directory
if [ -d "$PLUGIN_DIR" ]; then
    echo "[OK] Plugin directory exists"
else
    echo "[FAIL] Plugin directory missing: $PLUGIN_DIR"
    ERRORS=$((ERRORS + 1))
fi

# 2. Plugin entry point
if [ -f "$PLUGIN_DIR/tmux-claude-hooks-status.tmux" ]; then
    echo "[OK] Plugin entry point exists"
else
    echo "[FAIL] Plugin entry point missing"
    ERRORS=$((ERRORS + 1))
fi

# 3. Hook script
if [ -f "$PLUGIN_DIR/scripts/tmux-powerline-claude-status" ]; then
    echo "[OK] Hook script exists"
else
    echo "[FAIL] Hook script missing"
    ERRORS=$((ERRORS + 1))
fi

# 4. Hooks registration
if [ -f "$SETTINGS_FILE" ] && command -v python3 &>/dev/null; then
    HOOK_COUNT=$(python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    data = json.loads(f.read(), strict=False)
target = '$PLUGIN_DIR/scripts/tmux-powerline-claude-status'
count = sum(1 for groups in data.get('hooks', {}).values() for g in groups for h in g.get('hooks', []) if h.get('command') == target)
print(count)
")
    if [ "${HOOK_COUNT:-0}" -gt 0 ]; then
        echo "[OK] $HOOK_COUNT hooks registered"
    else
        echo "[FAIL] No hooks found"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "[WARN] Cannot check hooks registration"
fi

# 5. .tmux.conf declaration
if grep -q "tmux-claude-hooks-status" ~/.tmux.conf 2>/dev/null; then
    echo "[OK] Plugin declared in .tmux.conf"
else
    echo "[FAIL] Plugin not declared in .tmux.conf"
    ERRORS=$((ERRORS + 1))
fi

# 6. Live tmux test
if tmux info &>/dev/null; then
    echo '{}' | bash "$PLUGIN_DIR/scripts/tmux-powerline-claude-status" SessionStart 2>/dev/null
    STATUS=$(tmux show-option -g @claude_all_status 2>/dev/null)
    if [ -n "$STATUS" ]; then
        echo "[OK] Live tmux status: $STATUS"
    else
        echo "[WARN] Cannot get tmux status (may need tmux restart)"
    fi
else
    echo "[SKIP] No running tmux server"
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "========== Installation Successful =========="
    echo ""
    echo "Keyboard shortcuts:"
    echo "  prefix + C-h  — Install hooks"
    echo "  prefix + C-u  — Uninstall hooks"
    echo "  prefix + I    — TPM install all plugins"
    echo "  prefix + r    — Reload config"
else
    echo "========== $ERRORS check(s) failed =========="
    echo "Review the output above and fix manually."
fi
```
