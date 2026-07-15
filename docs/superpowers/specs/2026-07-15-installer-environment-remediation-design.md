# Installer Environment Remediation Design

**Date:** 2026-07-15

## Context

The Node TUI already checks `tmux`, `jq`, `bash`, and Node.js, and can run `brew install` for every failed check. It does not distinguish a missing dependency from an outdated dependency, cannot select `brew upgrade`, does not verify whether Homebrew owns an outdated package, and does not re-run checks after remediation. The repository also still presents `AI_INSTALL.md` and `AI_UNINSTALL.md` as primary installation workflows even though the TUI now owns those operations.

## Scope

This change makes the existing environment doctor capable of safely installing missing dependencies and upgrading outdated Homebrew-managed dependencies.

Included:

- classify environment dependencies as `ready`, `missing`, or `outdated`;
- use Homebrew to install missing dependencies;
- use Homebrew to upgrade outdated dependencies only when Homebrew owns the formula;
- leave unmanaged outdated dependencies untouched and print a manual recommendation;
- continue attempting other selected repairs when one repair fails;
- automatically re-check and display the environment after attempted repairs;
- reduce `AI_INSTALL.md` and `AI_UNINSTALL.md` to compatibility/fallback entry points;
- make the TUI the primary documented install/uninstall workflow.

Excluded:

- installing Homebrew itself;
- Linux package managers such as apt, dnf, or pacman;
- automatically installing or upgrading Claude Code or Codex CLI;
- replacing shell-level bootstrap logic for systems whose Node.js cannot start the TUI;
- proactively upgrading bash when a usable bash already exists.

## User Experience

The Doctor screen displays one of three markers:

- `✓ ready`: dependency exists and satisfies its minimum version;
- `✗ missing`: dependency is not installed;
- `⚠ outdated`: dependency exists but is below the minimum version.

When every dependency is ready, Doctor exits successfully without prompting.

When Homebrew is unavailable, Doctor prints manual commands and makes no changes.

When Homebrew is available, Doctor creates a remediation plan:

| Dependency state | Homebrew ownership | Action |
| --- | --- | --- |
| missing | not applicable | `brew install <formula>` |
| outdated | owned by Homebrew | `brew upgrade <formula>` |
| outdated | not owned by Homebrew | manual guidance only |
| ready | any | no action |

The user selects from only the automatically actionable entries. Each selection shows its exact command. After execution, failures are reported per dependency without stopping later selections. Doctor then runs the complete environment check again and renders the final state.

## Architecture

### Detection (`installer/src/detect.js`)

`checkEnv()` retains its current result shape for compatibility and adds a `status` field. `ok` remains true only for `ready`. Version-based dependencies (`tmux`, Node.js) become `outdated` when found below their minimum; presence-only dependencies (`jq`, `bash`) are either `ready` or `missing`.

`checkEnv()` accepts an optional probe dependency for deterministic tests while production continues to use `execa`.

### Remediation (`installer/src/env.js`)

Homebrew-specific behavior remains isolated in this module:

- `hasBrew()` verifies that `brew --version` exits successfully;
- `brewManages(formula)` checks `brew list --versions <formula>`;
- `planBrewRemediation(results)` maps failed detection results to `install`, `upgrade`, or `manual` actions;
- `runBrewAction(action, formula)` executes only the allow-listed actions `install` and `upgrade`;
- `brewInstall()` remains as a compatibility wrapper and `brewUpgrade()` is added.

Command execution accepts injected runners in tests. No test invokes the real network or modifies the host package manager.

### TUI orchestration (`installer/bin/cli.js`)

Doctor will:

1. run and render the initial environment check;
2. build the Homebrew remediation plan;
3. print manual-only items;
4. prompt for actionable install/upgrade operations;
5. execute selected operations independently;
6. re-run and render the full environment check.

AI CLI detection remains read-only. It may display minimum-version guidance but does not install or upgrade global AI CLI packages.

## Documentation Strategy

`AI_INSTALL.md` and `AI_UNINSTALL.md` remain in place to avoid breaking raw GitHub URLs and existing agent workflows. They become short compatibility documents that:

- direct full install/uninstall operations to the repository-backed TUI (`npm start` or `prefix + I`);
- describe `npx tmuxclihook` accurately as an environment/AI-CLI check entry because the published package does not include root `scripts/`;
- explain that environment repair and hook management belong to the CLI;
- retain only minimal no-TTY/failure-recovery commands;
- link readers back to the main README for full configuration.

`README.md`, `README_ZH.md`, `installer/README.md`, and `CLAUDE.md` will describe the TUI as the primary workflow and accurately state the Homebrew install/upgrade safety rules.

## Error Handling and Safety

- Only `install` and `upgrade` are accepted as executable Homebrew actions.
- Outdated non-Homebrew installations are never modified.
- Homebrew absence never triggers Homebrew installation.
- A failed formula operation is reported and does not abort later operations.
- The final re-check is authoritative; a successful command message does not by itself claim the environment is ready.
- Manual guidance includes the exact suggested command but leaves ownership decisions to the user.

## Testing

Node's built-in test runner will cover:

- dependency status classification for ready, missing, and outdated states;
- Homebrew availability based on exit status;
- ownership detection;
- remediation planning for missing, managed outdated, unmanaged outdated, and no-Homebrew cases;
- allow-listed Homebrew command execution and failure reporting;
- preservation of the existing Unicode-safe TUI rendering tests.

Static syntax checks and the full installer test suite must pass before commit.
