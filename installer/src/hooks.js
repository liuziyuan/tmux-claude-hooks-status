// hooks.js — 调 bash wrapper 完成 hooks 装/卸/修
import { execa } from 'execa';
import { existsSync } from 'node:fs';
import { toolById } from './adapters-meta.js';
import { hooksInstalled } from './detect.js';

// 安装某工具 hooks（调薄 wrapper install-<tool>-hooks.sh）
export async function installHooks(id) {
  const tool = toolById(id);
  if (!tool) return { ok: false, output: `未知工具: ${id}` };
  if (!existsSync(tool.installer)) return { ok: false, output: `找不到安装脚本: ${tool.installer}` };
  try {
    const { stdout } = await execa('bash', [tool.installer], { timeout: 30000 });
    return { ok: true, output: stdout };
  } catch (err) {
    return { ok: false, output: err.stderr || err.shortMessage || String(err) };
  }
}

// 卸载某工具 hooks
export async function uninstallHooks(id) {
  const tool = toolById(id);
  if (!tool) return { ok: false, output: `未知工具: ${id}` };
  if (!existsSync(tool.installer)) return { ok: false, output: `找不到安装脚本: ${tool.installer}` };
  try {
    const { stdout } = await execa('bash', [tool.installer, 'uninstall'], { timeout: 30000 });
    return { ok: true, output: stdout };
  } catch (err) {
    return { ok: false, output: err.stderr || err.shortMessage || String(err) };
  }
}

// 修复某工具 hooks：完整性检查（JS 侧 hooksInstalled）→ 缺失则重装
export async function repairHooks(id) {
  const tool = toolById(id);
  if (!tool) return { ok: false, output: `未知工具: ${id}` };
  if (hooksInstalled(tool)) {
    return { ok: true, output: `${tool.label} hooks 完整，无需修复`, repaired: false };
  }
  const r = await installHooks(id);
  return { ...r, repaired: r.ok };
}
