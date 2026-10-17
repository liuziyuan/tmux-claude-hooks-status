// check-detail.js — wrapper `check --json` 的解析、规范化与人类可读渲染
//
// `tmuxclihook check` 子命令与 TUI「侦测 AI CLI」明细共用；判定逻辑全在 bash 侧
// （adapter_check_detail + lib-install-hooks.sh 的 _wrapper_check_json），本模块只做
// 解析与渲染，不重复实现判定（避免两处真源）。status 永远以 bash 的判定为准。
import { execa } from 'execa';

const OK = '✓';
const NO = '✗';
const WARN = '⚠';

const MODE_LABEL = {
  file: '配置文件',
  ccswitch: 'cc-switch db（通用配置）',
  plugin: 'opencode plugin 文件',
  unknown: '未知',
};

function defaultRun(tool) {
  return execa('bash', [tool.installer, 'check', '--json'], { reject: false, timeout: 15000 });
}

function baseDetail(tool) {
  return {
    ok: false,
    tool: tool.id,
    label: tool.label,
    status: 'unknown',
    mode: 'unknown',
    suppress: false,
    events: {},
    plugin: null,
    registeredPaths: [],
    drift: null,
    error: null,
    raw: null,
  };
}

// 调某工具 wrapper 的 check --json 并解析规范化。
// 返回 baseDetail 的超集；status='unknown' 表示 wrapper 输出无法采信
// （脚本缺失 / 输出非 JSON / jq 缺失的 error JSON），error 字段给出原因。
// run 可注入供单测（沿用 env.test.js 的依赖注入风格）。
export async function checkToolDetail(tool, { run } = {}) {
  const runFn = run || defaultRun;
  let res;
  try {
    res = await runFn(tool);
  } catch (err) {
    return { ...baseDetail(tool), error: err.shortMessage || String(err) };
  }
  const stdout = String(res.stdout ?? '').trim();
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return {
      ...baseDetail(tool),
      error: `wrapper 输出不是合法 JSON（exit ${res.exitCode ?? '?'}）：${stdout.slice(0, 200)}`,
      raw: stdout,
    };
  }
  if (parsed.error) {
    return {
      ...baseDetail(tool),
      status: parsed.status === 'ok' ? 'ok' : 'unknown',
      mode: parsed.mode || 'unknown',
      suppress: Boolean(parsed.suppress),
      events: parsed.events || {},
      plugin: parsed.plugin ?? null,
      registeredPaths: parsed.registeredPaths || [],
      drift: parsed.drift || null,
      error: parsed.error,
      raw: stdout,
    };
  }
  const status = parsed.status === 'ok' ? 'ok' : 'missing';
  return {
    ...baseDetail(tool),
    ok: status === 'ok' && res.exitCode === 0,
    status,
    mode: parsed.mode || 'unknown',
    suppress: Boolean(parsed.suppress),
    events: parsed.events || {},
    plugin: parsed.plugin ?? null,
    registeredPaths: parsed.registeredPaths || [],
    drift: parsed.drift || null,
    raw: stdout,
  };
}

// 渲染单工具明细为人类可读行。drift 行用 ⚠ 前缀（脚本仍可用，功能未坏，
// 但指向的安装源不是当前 source——收敛入口在 TUI 侧）。
export function renderToolDetail(detail) {
  const lines = [];
  const modeNote = MODE_LABEL[detail.mode] || detail.mode;
  if (detail.status === 'ok') {
    lines.push(`  ${OK} hooks 完整（真源：${modeNote}）`);
  } else if (detail.status === 'missing') {
    lines.push(`  ${NO} hooks 缺失或损坏（真源：${modeNote}）`);
  } else {
    lines.push(`  ${NO} 无法判定：${detail.error || '未知错误'}`);
  }

  if (detail.suppress) {
    lines.push(`  ${WARN} 存在卸载意图标记（suppressed-${detail.tool}）：自动修复已被抑制`);
  }

  // 逐事件缺失明细（cc-switch/文件模式的 tools）
  if (detail.status === 'missing') {
    const broken = [];
    for (const [ev, e] of Object.entries(detail.events || {})) {
      if (!e || e.registered === 0) broken.push(`    ${NO} ${ev}：未注册`);
      else if (e.alive === 0) {
        broken.push(`    ${NO} ${ev}：脚本不可执行（${(e.scriptPaths || []).join(', ') || '未知路径'}）`);
      }
    }
    if (broken.length > 0) {
      lines.push('  缺失明细：');
      lines.push(...broken);
    }
  }

  // opencode plugin 明细（无逐事件概念，异常按布尔汇总）
  if (detail.plugin && detail.status === 'missing') {
    const pl = detail.plugin;
    if (!pl.exists) {
      lines.push(`  ${NO} plugin 文件不存在：${pl.path}`);
    } else {
      const marks = [];
      if (!pl.marker) marks.push('缺本插件标记');
      if (!pl.hookScriptAlive) marks.push('HOOK_SCRIPT 不可执行');
      for (const [k, v] of Object.entries(pl.structure || {})) {
        if (!v) marks.push(`缺结构片段 ${k}`);
      }
      if (marks.length > 0) lines.push(`  ${NO} plugin 异常：${marks.join('、')}`);
    }
  }

  // 注册路径与漂移
  if (detail.drift?.drifted) {
    lines.push(`  ${WARN} 漂移：hooks 指向其他安装源（脚本仍可用，check 仍判完整）`);
    for (const s of detail.drift.stale || []) lines.push(`      旧路径：${s}`);
    lines.push(`      当前 source 路径：${detail.drift.expected}`);
  } else if (detail.status !== 'unknown' && (detail.registeredPaths || []).length > 0) {
    for (const rp of detail.registeredPaths) lines.push(`  注册路径：${rp}`);
  }

  return lines;
}

// 多工具汇总（tmuxclihook check 的 exit code 与 TUI 收敛入口判定用）
export function summarizeDetails(details) {
  return {
    hasMissing: details.some((d) => d.status === 'missing'),
    hasDrift: details.some((d) => d.drift?.drifted),
    hasError: details.some((d) => d.status === 'unknown'),
  };
}
