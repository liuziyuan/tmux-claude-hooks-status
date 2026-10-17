// esc.js — 把 Esc 键转译为合成 ctrl+c
//
// clack 0.7 的 Prompt 仅把 \x03（ctrl+c）映射为 cancel（core 的 onKeypress 里
// 唯一的 cancel 触发是 ch === "\x03"），Esc 默认无任何效果——各子菜单的
// 「Esc 返回」此前只是文案承诺，从未生效。这里在 stdin 上挂全局 keypress
// 监听，看到 escape 键就向 stdin 注入合成 \x03，复用 clack 既有且经实测的
// ctrl+c cancel 路径：主菜单 Esc → isCancel → 退出；子菜单 Esc → isCancel →
// 返回主菜单；confirm/text Esc → isCancel → 各自的取消分支。
//
// spinner 期间不转译（与改动前一致：Esc 静默）。原因：clack 的 block() 给
// \x03 装了 process.exit(0) 的监听，若在 spinner 期间转译，Esc 会硬退出 TUI
// 且不恢复 raw mode；ctrl+c 行为不变（仍走该路径，与既有行为一致）。

let spinnerDepth = 0;

export function setSpinnerActive(on) {
  spinnerDepth += on ? 1 : -1;
  if (spinnerDepth < 0) spinnerDepth = 0;
}

// 返回解绑函数（进程退出即回收，正常无需调用；导出以便单测）。
export function enableEscapeCancel() {
  const onKeypress = (ch, key) => {
    if (spinnerDepth === 0 && key?.name === 'escape') {
      // 直接 emit 合成 keypress（ch='\x03'）：clack 的 onKeypress 以 ch === '\x03'
      // 判定 cancel，对它来说这与真实 ctrl+c 完全同构。不走 stdin.write——
      // raw mode（-echo）下向 fd 0 写入不会回环成输入。
      process.stdin.emit('keypress', '\x03', { name: 'c', ctrl: true, sequence: '\x03' });
    }
  };
  process.stdin.on('keypress', onKeypress);
  return () => process.stdin.off('keypress', onKeypress);
}
