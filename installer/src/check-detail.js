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
  'ccswitch-live': 'cc-switch 4.0+（~/.claude/settings.json）',
  ccswitch: 'cc-switch 旧版 db（通用配置）',
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
    // codex 授信维度：{configFile, trusted: true|false|null, missingEvents, instances}
    // 仅 codex adapter 提供；null = 该工具无此概念/旧版 adapter。
    trust: null,
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
      trust: parsed.trust ?? null,
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
    trust: parsed.trust ?? null,
    drift: parsed.drift || null,
    raw: stdout,
  };
}

// 重复注册检测：同事件下 registered > 1 表示有多条本插件 command（跨 group 或多 group）。
// 只用于提示——codex 重写 hooks.json 会使 trusted_hash 失效，因此不自动收敛。
export function findDuplicateEvents(detail) {
  return Object.entries(detail?.events || {})
    .filter(([, e]) => Number(e?.registered) > 1)
    .map(([event, e]) => ({ event, registered: Number(e.registered) }));
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

  // codex 重复注册：功能性提示（status 仍 ok、exit code 不变），收敛需显式操作
  if (detail.tool === 'codex') {
    const dups = findDuplicateEvents(detail);
    if (dups.length > 0) {
      const list = dups.map((d) => `${d.event}×${d.registered}`).join('、');
      lines.push(
        `  ${WARN} codex hooks 重复注册：${list}——codex 不会自动收敛（重写 hooks.json 会使 trusted_hash 失效，需要重新 Trust all）；可用 TMUX_AI_FORCE_INSTALL=1 重跑 install-codex-hooks.sh，或使用 TUI 收敛入口（会先确认 re-trust 代价）`
      );
    }
  }

  if (detail.suppress) {
    lines.push(`  ${WARN} 存在卸载意图标记（suppressed-${detail.tool}）：自动修复已被抑制`);
  }

  // codex 授信维度：hooks 注册完整 ≠ 会执行。键缺失 = 一定不执行；键存在只说明
  // 有授信记录（bash 无法复现 trusted_hash，改写后仍可能需重新 Trust）。
  const trust = detail.trust;
  if (trust) {
    if (trust.trusted === false) {
      const miss = (trust.missingEvents || []).join(', ') || '全部事件';
      lines.push(
        `  ${WARN} hooks 未授信：当前实例缺少 [hooks.state] 记录（${miss}）——codex 会跳过这些 hook，请在 codex TUI 选择 "Trust all and continue"`
      );
    } else if (trust.trusted === true) {
      lines.push(`  ${OK} 授信记录存在（键存在不等于 hash 匹配：hooks 改写后仍可能需重新 Trust）`);
    } else if (detail.status === 'ok') {
      lines.push(`  ${WARN} 无法判定授信状态：${trust.configFile} 不存在`);
    }
    const otherUntrusted = (trust.instances || []).filter(
      (i) => i.configFile !== trust.configFile && i.trusted === false
    );
    if (otherUntrusted.length > 0) {
      lines.push(`  ${WARN} 其他实例未授信（首次启动会弹 Hooks need review）：`);
      for (const i of otherUntrusted) {
        const miss = (i.missingEvents || []).join(', ') || '全部事件';
        lines.push(`      ${i.configFile}（缺 ${miss}）`);
      }
    }
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
