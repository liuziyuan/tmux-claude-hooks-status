// `tmuxclihook help` 的静态文案。独立成模块是为了让测试可以直接 import，
// 而不必加载 bin/cli.js（入口文件顶层会执行参数分支，未知参数会启动 TUI）。
const COMMAND_WIDTH = 26;

function line(command, description) {
  return `  ${command.padEnd(COMMAND_WIDTH)}  ${description}`;
}

export const HELP_TEXT = [
  'tmuxclihook — tmux-ai-status 交互式安装器',
  '',
  '命令行：',
  line('tmuxclihook', '打开交互式 TUI 安装器'),
  line('tmuxclihook check', 'hooks 健康明细（可跟 claude|codex|opencode；exit 1 = 有缺失或漂移）'),
  line('tmuxclihook update', '按当前安装方式（npm/volta）检查并更新到最新版本'),
  line('tmuxclihook update --prune', '更新后删除不生效的另一份安装；已是最新时也会执行清理'),
  line('tmuxclihook version', '显示版本（--version / -v 等价）'),
  line('tmuxclihook help', '显示本帮助（--help / -h 等价）'),
  '',
  'tmux 快捷键（插件加载后生效）：',
  line('prefix + I', '打开交互式 TUI 安装器'),
  line('prefix + C-h', '安装 Claude Code hooks'),
  line('prefix + C-u', '卸载 Claude Code hooks'),
  line('prefix + M-h', '安装 Codex hooks'),
  line('prefix + M-u', '卸载 Codex hooks'),
  line('prefix + C-p', '安装 opencode plugin'),
  line('prefix + M-p', '卸载 opencode plugin'),
  line('prefix + r', '重载配置（含本插件初始化）'),
  '',
  'prefix 默认是 Ctrl+b；若你在 tmux 配置中改过 prefix，以你的配置为准。',
].join('\n');
