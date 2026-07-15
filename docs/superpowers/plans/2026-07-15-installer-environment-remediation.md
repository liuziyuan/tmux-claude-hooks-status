# Installer Environment Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely install missing environment dependencies and upgrade outdated Homebrew-managed dependencies from the TUI, then make the TUI the primary documented install/uninstall path.

**Architecture:** Detection classifies dependency state without making changes. A Homebrew-specific remediation module converts failed checks into explicit install, upgrade, or manual actions, while the CLI orchestrates confirmation, execution, and final verification. AI CLI installation and upgrades remain outside automation.

**Tech Stack:** Node.js 18+ ESM, `execa`, `@clack/prompts`, Node built-in test runner, Markdown.

---

## File Map

- Modify `installer/src/detect.js`: add deterministic dependency-state classification and injectable probing.
- Modify `installer/src/env.js`: add Homebrew ownership checks, remediation planning, upgrades, and safe command execution.
- Modify `installer/bin/cli.js`: render richer states, prompt for planned actions, execute them, and re-check.
- Create `installer/test/detect.test.js`: verify environment-state classification.
- Create `installer/test/env.test.js`: verify remediation planning and Homebrew command behavior without touching real Homebrew.
- Modify `installer/README.md`: document safe automatic install/upgrade behavior.
- Modify `README.md`: replace raw AI-manual commands with the TUI-first workflow.
- Modify `README_ZH.md`: replace the AI-agent-first workflow with the TUI-first workflow.
- Modify `AI_INSTALL.md`: retain a short compatibility and fallback install entry point.
- Modify `AI_UNINSTALL.md`: retain a short compatibility and fallback uninstall entry point.
- Modify `CLAUDE.md`: update maintainer architecture and behavior notes.

### Task 1: Classify Environment Dependency States

**Files:**
- Modify: `installer/src/detect.js`
- Create: `installer/test/detect.test.js`

- [ ] **Step 1: Write failing classification tests**

Create tests that inject probe results and assert:

```js
assert.equal(byName.tmux.status, 'outdated');
assert.equal(byName.jq.status, 'missing');
assert.equal(byName.bash.status, 'ready');
assert.equal(byName.node.status, 'ready');
assert.equal(byName.tmux.ok, false);
```

Also cover an all-ready result set and confirm every `ok` value remains compatible with `status === 'ready'`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
cd installer && node --test test/detect.test.js
```

Expected: FAIL because `checkEnv()` does not accept an injected probe and results do not contain `status`.

- [ ] **Step 3: Implement minimal classification**

Add a pure result builder that returns:

```js
{
  name,
  status: found ? (meetsMinimum ? 'ready' : 'outdated') : 'missing',
  ok: status === 'ready',
  detail,
  min,
  fixCmd,
  pkg,
}
```

Presence-only checks use `found` as `meetsMinimum`. Change `checkEnv()` to accept `{ probeCommand = probe } = {}` and use that function for every probe.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
cd installer && node --test test/detect.test.js
```

Expected: all detection tests PASS.

### Task 2: Plan and Execute Safe Homebrew Remediation

**Files:**
- Modify: `installer/src/env.js`
- Create: `installer/test/env.test.js`

- [ ] **Step 1: Write failing remediation tests**

Cover these exact decisions:

```js
missing   -> { action: 'install', command: 'brew install jq' }
outdated + managed   -> { action: 'upgrade', command: 'brew upgrade tmux' }
outdated + unmanaged -> { action: 'manual' }
no Homebrew          -> { action: 'manual' }
ready                 -> omitted
```

Use fake runners to assert `brew --version`, `brew list --versions tmux`, `brew install jq`, and `brew upgrade tmux` argument arrays. Add a rejection test for an action other than `install` or `upgrade`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
cd installer && node --test test/env.test.js
```

Expected: FAIL because ownership, upgrade, planning, and generic action APIs do not exist.

- [ ] **Step 3: Implement Homebrew capability and planning APIs**

Implement:

```js
hasBrew({ runner = execa } = {})
brewManages(pkg, { runner = execa } = {})
planBrewRemediation(results, { brewAvailable, manages } = {})
runBrewAction(action, pkg, { onLine, runner = execa } = {})
brewInstall(pkg, onLine, options)
brewUpgrade(pkg, onLine, options)
```

`hasBrew()` and `brewManages()` must require `exitCode === 0`. `runBrewAction()` must throw before spawning when action is not allow-listed. Planning must never query ownership for missing packages or ready results.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
cd installer && node --test test/env.test.js
```

Expected: all remediation tests PASS and no real `brew` command executes.

### Task 3: Integrate Remediation into Doctor

**Files:**
- Modify: `installer/bin/cli.js`

- [ ] **Step 1: Add state-aware rendering**

Render markers using:

```js
const mark = r.status === 'ready' ? '✓' : r.status === 'outdated' ? '⚠' : '✗';
```

Keep the existing aligned Unicode cards and shell explanation.

- [ ] **Step 2: Replace blanket install selection with planned actions**

Call `planBrewRemediation(results)`. Print manual entries separately, and build multiselect options only from `install` or `upgrade` entries. Each label must contain the exact command, for example `tmux — brew upgrade tmux`.

- [ ] **Step 3: Execute selections independently**

For each selected plan entry, call:

```js
await runBrewAction(entry.action, entry.pkg)
```

Use a separate spinner and success/failure message per item. Continue after failures.

- [ ] **Step 4: Re-check after attempted repairs**

After at least one selected action, call `checkEnv()` again, render a `修复后环境` card, and report success only if every final result has `status === 'ready'`.

- [ ] **Step 5: Run syntax and full tests**

Run:

```bash
cd installer && npm run check && npm test
```

Expected: syntax check succeeds and all tests PASS.

### Task 4: Make the TUI the Primary Documentation Workflow

**Files:**
- Modify: `README.md`
- Modify: `README_ZH.md`
- Modify: `installer/README.md`
- Modify: `AI_INSTALL.md`
- Modify: `AI_UNINSTALL.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace primary install/uninstall commands**

Document the repository-backed TUI (`cd installer && npm start`) as the full standalone entry point and `prefix + I` as the installed tmux entry point. Document `npx tmuxclihook` only for environment/AI-CLI checks because the npm package does not ship root scripts. Remove the raw `ai .../AI_INSTALL.md` and `ai .../AI_UNINSTALL.md` commands from the primary quick-start sections.

- [ ] **Step 2: Convert AI manuals into compatibility stubs**

Keep both filenames, explain why they remain, direct interactive users to the TUI, and retain only minimal repository-script fallback commands for no-TTY or recovery use.

- [ ] **Step 3: Document exact remediation safety rules**

State that the Doctor:

- installs missing Homebrew formulas;
- upgrades only outdated Homebrew-managed formulas;
- does not install Homebrew;
- does not modify unmanaged installations;
- does not automatically install or upgrade Claude Code or Codex CLI;
- re-checks the environment after repairs.

- [ ] **Step 4: Check documentation consistency**

Run:

```bash
grep -RIn 'ai https://raw.githubusercontent.com/.*/AI_\(INSTALL\|UNINSTALL\)\.md' README.md README_ZH.md installer/README.md CLAUDE.md
```

Expected: no matches in primary documentation.

### Task 5: Final Verification and Commit

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run the complete installer verification**

Run:

```bash
cd installer && npm run check && npm test
```

Expected: all syntax checks and tests PASS with no warnings.

- [ ] **Step 2: Review the final diff and status**

Run:

```bash
git diff --check
git status --short
git diff --stat
git diff
```

Expected: no whitespace errors; only intended installer, test, design, plan, and documentation changes appear. Preserve the pre-existing package rename and Unicode TUI changes.

- [ ] **Step 3: Commit the cohesive installer change**

Stage the installer implementation, existing related TUI/package changes, tests, design, plan, and documentation, then commit:

```bash
git commit -m "feat(installer): add safe environment remediation"
```

Expected: commit succeeds and `git status --short` is empty.
