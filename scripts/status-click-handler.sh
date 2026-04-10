#!/bin/bash
# status-click-handler.sh: 点击状态栏 Claude 状态项后跳转到对应 pane
# 由 tmux MouseDown1StatusDefault 绑定调用，$1 = #{mouse_status_range}（pane_id，如 %2）

PANE_ID="$1"
# 只处理 tmux pane ID（%N 格式），其余点击直接忽略
[[ "$PANE_ID" =~ ^%[0-9]+$ ]] || exit 0

# 通过 pane_id 找到所属 session 和 window
read -r SESSION WINDOW <<< "$(tmux list-panes -a \
    -F "#{pane_id} #{session_name} #{window_id}" 2>/dev/null \
    | awk -v id="$PANE_ID" '$1==id{print $2, $3; exit}')"

[ -z "$SESSION" ] && exit 0

tmux switch-client -t "$SESSION"
tmux select-window -t "$WINDOW"
tmux select-pane -t "$PANE_ID"
