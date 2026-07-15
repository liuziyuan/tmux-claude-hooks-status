#!/usr/bin/env node
// cli.js — tmux-ai-status 交互式安装 TUI（@clack/prompts）
//
// 主菜单：环境检查 / 侦测 CLI / 安装 / 卸载 / 修复 hooks / tmux 软链。
// 实际 hooks 逻辑委托 bash wrapper（scripts/install-<tool>-hooks.sh）。

import * as p from '@clack/prompts';
import { checkEnv, detectClis, interactiveShell } from '../src/detect.js';
import { hasBrew, brewInstall } from '../src/env.js';
import { installHooks, uninstallHooks, repairHooks } from '../src/hooks.js';
import { checkSymlink, createSymlink, checkTmuxConf } from '../src/symlink.js';
import { TOOLS, repoExists, REPO_ROOT } from '../src/adapters-meta.js';

const OK = '✓';
const NO = '✗';

async function doctor() {
  const s = p.spinner();
  s.start('检查环境依赖');
  const results = await checkEnv();
  s.stop('环境检查完成');

  const lines = results.map((r) => {
    const mark = r.ok ? OK : NO;
    return `  ${mark} ${r.name.padEnd(6)} ${r.detail.padEnd(16)} (要求 ${r.min})`;
  });
  p.note(lines.join('\n'), '环境依赖');

  // 交互 shell 说明：消除「我用 zsh 但 Doctor 检查 bash」的困惑
  const sh = interactiveShell();
  p.note(
    `  当前交互 shell：${sh.name}（${sh.path}）\n` +
    `  说明：hook 脚本 shebang 为 #!/bin/bash，由 AI CLI 触发时以 bash 执行，\n` +
    `        与你的交互 shell（${sh.name}）无关。macOS 自带 bash 3.2 即可，无需升级。`,
    'shell 说明',
  );

  const missing = results.filter((r) => !r.ok);
  if (missing.length === 0) {
    p.log.success('所有依赖就绪');
    return;
  }

  const brew = await hasBrew();
  if (!brew) {
    p.log.warn('缺失依赖，且未检测到 brew。请手动安装：');
    missing.forEach((m) => p.log.message(`  ${m.fixCmd}`));
    return;
  }

  const pick = await p.multiselect({
    message: '选择要代装的缺失依赖（brew install）',
    options: missing.map((m) => ({ value: m.pkg, label: `${m.name} — ${m.fixCmd}` })),
    required: false,
  });
  if (p.isCancel(pick) || !pick || pick.length === 0) {
    p.log.info('跳过代装。手动命令：');
    missing.forEach((m) => p.log.message(`  ${m.fixCmd}`));
    return;
  }

  for (const pkg of pick) {
    const s2 = p.spinner();
    s2.start(`brew install ${pkg}`);
    const r = await brewInstall(pkg);
    if (r.ok) s2.stop(`${OK} ${pkg} 安装完成`);
    else s2.stop(`${NO} ${pkg} 安装失败: ${r.output}`);
  }
}

async function detectCliMenu() {
  const s = p.spinner();
  s.start('侦测已安装的 AI CLI');
  const rows = await detectClis();
  s.stop('侦测完成');

  const lines = rows.map((r) => {
    if (!r.installed) return `  ${NO} ${r.label.padEnd(14)} 未安装`;
    const verMark = r.meetsMin ? OK : '⚠';
    const minNote = r.minVersion && !r.meetsMin ? ` (需 ≥ ${r.minVersion})` : '';
    const hookNote = r.hooksInstalled ? '已装 hooks' : '未装 hooks';
    return `  ${verMark} ${r.label.padEnd(14)} v${r.version}${minNote}  ${hookNote}`;
  });
  p.note(lines.join('\n'), 'AI CLI');
}

async function pickTool(message) {
  const rows = await detectClis();
  const opts = TOOLS.map((t) => {
    const row = rows.find((r) => r.id === t.id);
    const hint = !row?.installed ? '未安装' : row.hooksInstalled ? '已装 hooks' : '未装 hooks';
    return { value: t.id, label: t.label, hint };
  });
  opts.push({ value: '__all__', label: '全部', hint: 'claude + codex' });
  const sel = await p.select({ message, options: opts });
  return p.isCancel(sel) ? null : sel;
}

async function runHookAction(action, verb) {
  const sel = await pickTool(`选择要${verb}的工具`);
  if (!sel) return;
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

async function symlinkMenu() {
  const st = checkSymlink();
  const conf = checkTmuxConf();
  const lines = [
    `  软链 ${PLUGIN_LINE(st)}`,
    `  .tmux.conf: ${conf.exists ? (conf.referenced ? `${OK} 已引用插件` : `${NO} 未引用（需手动加 @plugin 或 run）`) : `${NO} 不存在`}`,
  ];
  p.note(lines.join('\n'), 'tmux 软链');

  if (st.status === 'ok') {
    p.log.success('软链正常');
    return;
  }
  const go = await p.confirm({ message: `创建软链 ${PLUGIN_LINK_PATH()} → 仓库？` });
  if (p.isCancel(go) || !go) return;
  const r = createSymlink();
  if (r.ok) p.log.success(`${OK} 软链已创建：${r.from} → ${r.to}`);
  else p.log.error(`${NO} 创建失败：${r.output}`);
}

function PLUGIN_LINE(st) {
  if (st.status === 'ok') return `${OK} ${st.note || '指向本仓库'}`;
  if (st.status === 'missing') return `${NO} 不存在`;
  return `${NO} 错误（${st.reason || '指向其他位置'}）`;
}
function PLUGIN_LINK_PATH() {
  return '~/.tmux/plugins/tmux-ai-hooks-status';
}

async function main() {
  p.intro('tmux-ai-status 安装器');

  if (!repoExists) {
    p.log.warn(`未定位到仓库 scripts/（期望 ${REPO_ROOT}）。若通过 npx 运行，请在仓库内或已装插件目录下运行。`);
  }

  while (true) {
    const choice = await p.select({
      message: '选择操作',
      options: [
        { value: 'doctor', label: '环境检查', hint: 'tmux / jq / bash / node' },
        { value: 'detect', label: '侦测 AI CLI', hint: '版本 + hooks 状态' },
        { value: 'install', label: '安装 hooks' },
        { value: 'uninstall', label: '卸载 hooks' },
        { value: 'repair', label: '修复 hooks', hint: '完整性检查 + 缺失重装' },
        { value: 'symlink', label: 'tmux 软链校验' },
        { value: 'exit', label: '退出' },
      ],
    });
    if (p.isCancel(choice) || choice === 'exit') break;

    try {
      if (choice === 'doctor') await doctor();
      else if (choice === 'detect') await detectCliMenu();
      else if (choice === 'install') await runHookAction(installHooks, '安装');
      else if (choice === 'uninstall') await runHookAction(uninstallHooks, '卸载');
      else if (choice === 'repair') await runHookAction(repairHooks, '修复');
      else if (choice === 'symlink') await symlinkMenu();
    } catch (err) {
      p.log.error(String(err));
    }
  }

  p.outro('完成');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
