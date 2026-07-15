#!/usr/bin/env node
// cli.js — tmux-ai-status 交互式安装 TUI（@clack/prompts）
//
// 主菜单：环境检查 / 侦测 CLI / 安装 / 卸载 / 修复 hooks / tmux 集成 / source 管理。
// 实际 hooks 逻辑委托 bash wrapper（scripts/install-<tool>-hooks.sh）。
//
// "source" 决定 scripts/ 与 tmux 入口来自哪里：环境变量 TMUXCLIHOOK_SOURCE >
// 持久化配置 ~/.config/tmuxclihook/config.json > 包内自带（生产默认）> 仓库根
// （开发回落）。见 src/source.js 与 docs/2026-07-15-npm-global-install-plan.md。

import { homedir } from 'node:os';
import * as p from '@clack/prompts';
import { checkEnv, detectClis, interactiveShell } from '../src/detect.js';
import { planBrewRemediation, runBrewAction } from '../src/env.js';
import { installHooks, uninstallHooks, repairHooks } from '../src/hooks.js';
import { checkSymlink, checkTmuxConf } from '../src/symlink.js';
import { ensureTmuxIntegration, reloadTmux } from '../src/tmuxconf.js';
import { stopMonitor, clearAggregateStatus, removeSymlinks } from '../src/purge.js';
import {
  TOOLS,
  repoExists,
  REPO_ROOT,
  TMUX_ENTRY,
  SOURCE_ORIGIN,
  SOURCE_WARNINGS,
  refreshSource,
} from '../src/adapters-meta.js';
import { setSource, clearSource, getPersistedSource, originLabel } from '../src/source.js';
import { note, padDisplay } from '../src/tui.js';
import { updatePackage } from '../src/update.js';

const OK = '✓';
const NO = '✗';

function renderEnvResults(results, title = '环境依赖') {
  const lines = results.map((result) => {
    const mark = result.status === 'ready' ? OK : result.status === 'outdated' ? '⚠' : NO;
    return `  ${mark} ${padDisplay(result.name, 6)} ${padDisplay(result.detail, 16)} (要求 ${result.min})`;
  });
  note(lines.join('\n'), title);
}

async function doctor() {
  const s = p.spinner();
  s.start('检查环境依赖');
  const results = await checkEnv();
  s.stop('环境检查完成');

  renderEnvResults(results);

  // 交互 shell 说明：消除「我用 zsh 但 Doctor 检查 bash」的困惑
  const sh = interactiveShell();
  note(
    `  当前交互 shell：${sh.name}（${sh.path}）\n` +
    `  说明：hook 脚本 shebang 为 #!/bin/bash，由 AI CLI 触发时以 bash 执行，\n` +
    `        与你的交互 shell（${sh.name}）无关。macOS 自带 bash 3.2 即可，无需升级。`,
    'shell 说明',
  );

  const failed = results.filter((result) => result.status !== 'ready');
  if (failed.length === 0) {
    p.log.success('所有依赖就绪');
    return;
  }

  const plan = await planBrewRemediation(results);
  const manual = plan.filter((entry) => entry.action === 'manual');
  const actionable = plan.filter((entry) => entry.action !== 'manual');

  if (manual.length > 0) {
    p.log.warn('以下依赖不会自动修改：');
    manual.forEach((entry) => {
      p.log.message(`  ${entry.name}：${entry.reason}`);
    });
  }

  if (actionable.length === 0) {
    p.log.info('当前没有可由 Homebrew 自动修复的依赖');
    return;
  }

  const entryByKey = new Map(actionable.map((entry) => [
    `${entry.action}:${entry.pkg}`,
    entry,
  ]));
  const pick = await p.multiselect({
    message: '选择要自动修复的环境依赖',
    options: actionable.map((entry) => ({
      value: `${entry.action}:${entry.pkg}`,
      label: `${entry.name} — ${entry.command}`,
    })),
    required: false,
  });
  if (p.isCancel(pick) || !pick || pick.length === 0) {
    p.log.info('跳过自动修复。可手动执行：');
    actionable.forEach((entry) => p.log.message(`  ${entry.command}`));
    return;
  }

  for (const key of pick) {
    const entry = entryByKey.get(key);
    if (!entry) continue;

    const s2 = p.spinner();
    s2.start(entry.command);
    const result = await runBrewAction(entry.action, entry.pkg);
    if (result.ok) s2.stop(`${OK} ${entry.name} 修复命令执行完成`);
    else s2.stop(`${NO} ${entry.name} 修复失败: ${result.output}`);
  }

  const verifySpinner = p.spinner();
  verifySpinner.start('重新检查环境依赖');
  const finalResults = await checkEnv();
  verifySpinner.stop('环境复检完成');
  renderEnvResults(finalResults, '修复后环境');

  if (finalResults.every((result) => result.status === 'ready')) {
    p.log.success('所有依赖就绪');
  } else {
    p.log.warn('仍有依赖需要处理，请查看上方复检结果');
  }
}

async function detectCliMenu() {
  const s = p.spinner();
  s.start('侦测已安装的 AI CLI');
  const rows = await detectClis();
  s.stop('侦测完成');

  const lines = rows.map((r) => {
    if (!r.installed) return `  ${NO} ${padDisplay(r.label, 14)} 未安装`;
    const verMark = r.meetsMin ? OK : '⚠';
    const minNote = r.minVersion && !r.meetsMin ? ` (需 ≥ ${r.minVersion})` : '';
    const hookNote = r.hooksInstalled ? '已装 hooks' : '未装 hooks';
    return `  ${verMark} ${padDisplay(r.label, 14)} v${r.version}${minNote}  ${hookNote}`;
  });
  note(lines.join('\n'), 'AI CLI');
}

async function pickTool(message) {
  const rows = await detectClis();
  const opts = TOOLS.map((t) => {
    const row = rows.find((r) => r.id === t.id);
    const hint = !row?.installed ? '未安装' : row.hooksInstalled ? '已装 hooks' : '未装 hooks';
    return { value: t.id, label: t.label, hint };
  });
  opts.push({ value: '__all__', label: '全部', hint: TOOLS.map((t) => t.id).join(' + ') });
  opts.push({ value: '__back__', label: '← 返回主菜单' });
  const sel = await p.select({ message, options: opts });
  return p.isCancel(sel) || sel === '__back__' ? null : sel;
}

async function runHookAction(action, verb) {
  const sel = await pickTool(`选择要${verb}的工具（Esc 返回）`);
  if (!sel) { p.log.info('返回主菜单'); return; }
  const ids = sel === '__all__' ? TOOLS.map((t) => t.id) : [sel];
  for (const id of ids) {
    const s = p.spinner();
    s.start(`${verb} ${id} hooks`);
    const r = await action(id);
    if (r.ok) {
      s.stop(`${OK} ${id} ${verb}完成`);
      if (r.output) p.log.message(r.output.trim());
    } else {
      s.stop(`${NO} ${id} ${verb}失败`);
      p.log.error(r.output || '未知错误');
    }
  }
}

// tmux 集成：不再依赖 TPM 软链，直接检查/修复 .tmux.conf 里指向当前 source
// 的 run-shell 声明。历史遗留的 ~/.tmux/plugins/ 软链仅作提示，清理走「完整卸载插件」。
// 确认 + 应用「确保 tmux 集成」，被「tmux 集成」菜单与启动时的主动检测共用。
async function confirmAndApplyTmuxIntegration(conf) {
  const go = await p.confirm({
    message: conf.referenced
      ? '.tmux.conf 中的声明指向过期路径（例如切换了 source），更新为当前路径并重载？'
      : '.tmux.conf 未集成本插件，追加 run-shell 声明并重载？',
  });
  if (p.isCancel(go) || !go) return false;

  const r = ensureTmuxIntegration();
  if (!r.ok) { p.log.error(`${NO} 写入 .tmux.conf 失败：${r.output}`); return false; }
  if (r.action === 'created') p.log.success(`${OK} 已创建 ${r.path} 并写入声明`);
  else if (r.action === 'appended') p.log.success(`${OK} 已追加声明到 ${r.path}`);
  else if (r.action === 'replaced') p.log.success(`${OK} 已更新 ${r.path} 中的过期路径`);
  else p.log.info('无需变更');

  const rl = await reloadTmux();
  if (rl.ok) p.log.success(`${OK} 已重载 tmux 配置`);
  else p.log.warn(`重载失败（tmux 可能未运行）：${rl.output}\n请手动执行 tmux source-file ~/.tmux.conf`);
  return true;
}

async function tmuxIntegrationMenu() {
  const symlinkSt = checkSymlink();
  const conf = checkTmuxConf();
  const lines = [
    `  加载方式：run-shell '${TMUX_ENTRY}'`,
    `  .tmux.conf：${confStatusLine(conf)}`,
  ];
  if (symlinkSt.status === 'ok') {
    lines.push(`  历史遗留软链：检测到 ${symlinkSt.link}（新加载方式不再需要，可在「完整卸载插件」中一并清理）`);
  }
  note(lines.join('\n'), 'tmux 集成');

  if (conf.pointsToCurrent) {
    p.log.success('已正确集成，无需操作');
    return;
  }

  await confirmAndApplyTmuxIntegration(conf);
}

// 启动时主动检测：未集成 / 路径过期时主动提示，而非只在「tmux 集成」子菜单里被动
// 等用户发现。尤其覆盖"全新 .tmux.conf"场景——`npm i -g` 装完不会自动写入任何东西
// （没有 postinstall 钩子），必须经这一步或手动进「tmux 集成」菜单确认后才会写入。
async function maybeOfferTmuxIntegration() {
  const conf = checkTmuxConf();
  if (conf.pointsToCurrent) return;

  p.log.warn(
    conf.exists
      ? '.tmux.conf 尚未集成本插件（或路径已过期），状态栏与 hooks 不会自动生效。'
      : '未找到 ~/.tmux.conf，可创建一个新文件并写入本插件的加载声明。',
  );
  await confirmAndApplyTmuxIntegration(conf);
}

function confStatusLine(conf) {
  if (!conf.exists) return `${NO} 不存在`;
  if (conf.pointsToCurrent) return `${OK} 已指向当前安装`;
  if (conf.referenced) return `${NO} 已引用，但路径过期或为旧式声明`;
  return `${NO} 未集成`;
}

// source 管理：查看当前生效 source（含来源与失效警告），设置本地开发路径，
// 或清除持久化配置恢复默认。切换后仅影响"接下来"的 hooks 安装 / tmux 集成写入，
// 已写入的旧路径需要重新执行对应操作才会更新（见 docs 计划的残留风险第 4 条）。
function currentSourceLines() {
  const lines = [
    `  当前 source：${REPO_ROOT}`,
    `  来源：${originLabel(SOURCE_ORIGIN)}`,
  ];
  for (const w of SOURCE_WARNINGS) lines.push(`  ⚠ ${w}`);
  return lines;
}

async function sourceMenu() {
  note(currentSourceLines().join('\n'), 'source 状态');

  const persisted = getPersistedSource();
  const choice = await p.select({
    message: '选择操作（Esc 返回主菜单）',
    options: [
      { value: 'set', label: '设置本地开发路径', hint: '指向本地仓库，改代码即时生效' },
      {
        value: 'clear',
        label: '清除并恢复默认',
        hint: persisted ? `当前已保存：${persisted}` : '未设置持久化路径',
      },
      { value: '__back__', label: '← 返回主菜单' },
    ],
  });
  if (p.isCancel(choice) || choice === '__back__') return;

  if (choice === 'set') {
    const dir = await p.text({
      message: '输入本地仓库路径（需含 scripts/ 目录）',
      placeholder: '~/work/home/tmux-claude-hooks-status',
    });
    if (p.isCancel(dir) || !dir) { p.log.info('已取消'); return; }
    const expanded = dir.startsWith('~') ? dir.replace(/^~/, homedir()) : dir;
    const r = setSource(expanded);
    if (!r.ok) { p.log.error(`${NO} ${r.output}`); return; }
    refreshSource();
    p.log.success(`${OK} source 已切换到 ${r.source}`);
    p.log.warn('需重新执行「安装 hooks」与「tmux 集成」，新路径才会写入 hooks 配置 / .tmux.conf');
    return;
  }

  if (choice === 'clear') {
    const r = clearSource();
    if (!r.ok) { p.log.error(`${NO} ${r.output}`); return; }
    refreshSource();
    p.log.success(`${OK} 已清除，恢复默认（${originLabel(SOURCE_ORIGIN)}）`);
    p.log.warn('需重新执行「安装 hooks」与「tmux 集成」，默认路径才会写回 hooks 配置 / .tmux.conf');
  }
}

async function purgeMenu() {
  p.log.warn('完整卸载：停止 monitor、清聚合状态、清理历史遗留软链。hooks 请先在「卸载 hooks」菜单移除。');
  const go = await p.confirm({ message: '继续完整卸载插件运行态？（不删仓库、不改 .tmux.conf、不 kill-server）' });
  if (p.isCancel(go) || !go) { p.log.info('已取消'); return; }

  const mon = await stopMonitor();
  if (mon.ok) p.log.success(`${OK} 已停止 Codex monitor`);
  else p.log.warn(`monitor stop 失败（可能未运行）：${mon.output}`);

  const clr = await clearAggregateStatus();
  if (clr.ok) p.log.success(`${OK} 已清除 @ai_all_status`);
  else p.log.warn(`清除聚合状态失败（tmux 可能未运行）：${clr.output}`);

  const rm = removeSymlinks();
  if (rm.removed.length > 0) p.log.success(`${OK} 已清理历史遗留软链：${rm.removed.join(', ')}`);
  else p.log.info('无历史遗留软链需要清理');

  note(
    "  以下破坏性步骤请手动执行：\n" +
    `  1. 从 ~/.tmux.conf 删除本插件的 run-shell 声明（形如 run-shell '.../tmux-ai-hooks-status.tmux'，\n` +
    "     或历史遗留的 set -g @plugin 'tmux-ai-hooks-status'）\n" +
    "  2. 重启 tmux server 使状态行/hooks/按键完全卸载：tmux kill-server\n" +
    "     （kill-server 会关闭当前所有 session，请先保存工作）",
    '手动收尾',
  );
}

async function main() {
  p.intro('tmux-ai-status 安装器');

  note(currentSourceLines().join('\n'), 'source 状态');

  if (!repoExists) {
    p.log.warn(`当前 source（${REPO_ROOT}）下未找到 scripts/ 目录，hooks 安装与 tmux 集成将失败。请用「source 管理」指向一个有效仓库路径。`);
  } else {
    await maybeOfferTmuxIntegration();
  }

  while (true) {
    const choice = await p.select({
      message: '选择操作（Esc 在子菜单返回主页面）',
      options: [
        { value: 'doctor', label: '环境检查', hint: 'tmux / jq / bash / node' },
        { value: 'detect', label: '侦测 AI CLI', hint: '版本 + hooks 状态' },
        { value: 'install', label: '安装 hooks' },
        { value: 'uninstall', label: '卸载 hooks' },
        { value: 'repair', label: '修复 hooks', hint: '完整性检查 + 缺失重装' },
        { value: 'tmux', label: 'tmux 集成', hint: '校验/修复 .tmux.conf 的加载声明' },
        { value: 'source', label: 'source 管理', hint: '生产默认 / 切换本地调试路径' },
        { value: 'purge', label: '完整卸载插件', hint: 'monitor stop + 清状态 + 清历史软链' },
        { value: 'exit', label: '退出' },
      ],
    });
    // 主菜单是顶层：Esc（isCancel）不退出程序，留在主菜单；退出仅走「退出」项。
    if (p.isCancel(choice)) {
      p.log.info('已在主菜单（退出请选「退出」项）');
      continue;
    }
    if (choice === 'exit') break;

    try {
      if (choice === 'doctor') await doctor();
      else if (choice === 'detect') await detectCliMenu();
      else if (choice === 'install') await runHookAction(installHooks, '安装');
      else if (choice === 'uninstall') await runHookAction(uninstallHooks, '卸载');
      else if (choice === 'repair') await runHookAction(repairHooks, '修复');
      else if (choice === 'tmux') await tmuxIntegrationMenu();
      else if (choice === 'source') await sourceMenu();
      else if (choice === 'purge') await purgeMenu();
    } catch (err) {
      p.log.error(String(err));
    }
  }

  p.outro('完成');
}

if (process.argv[2] === 'update') {
  updatePackage().then((ok) => {
    if (!ok) process.exitCode = 1;
  }).catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
} else {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
