// env.js — 缺失依赖代装（仅限 brew）
import { execa } from 'execa';

// brew 是否可用
export async function hasBrew() {
  try {
    await execa('brew', ['--version'], { reject: false, timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

// 代跑 brew install <pkg>。返回 {ok, output}。
export async function brewInstall(pkg, onLine) {
  try {
    const sub = execa('brew', ['install', pkg]);
    if (onLine) {
      sub.stdout?.on('data', (d) => onLine(String(d)));
      sub.stderr?.on('data', (d) => onLine(String(d)));
    }
    await sub;
    return { ok: true };
  } catch (err) {
    return { ok: false, output: err.shortMessage || String(err) };
  }
}
