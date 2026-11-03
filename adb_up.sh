#!/data/data/com.termux/files/usr/bin/bash
# adb_up.sh — 确保 adb 服务在线（开机/掉线后跑一次即可）
set -u
D="127.0.0.1:5555"

# 1. 起一个脱离终端的 adb server，避免随 shell 退出而亡
if ! pgrep -f "adb.*fork-server" >/dev/null 2>&1; then
  setsid adb start-server >/dev/null 2>&1 < /dev/null &
  sleep 1.5
fi

# 2. 连接本机调试端口
adb connect "$D" >/dev/null 2>&1
sleep 1

# 3. 校验身份
UID_LINE=$(adb -s "$D" shell id 2>/dev/null)
if echo "$UID_LINE" | grep -q "uid=2000"; then
  echo "✅ 接続済み $D  ($(echo "$UID_LINE" | grep -o 'uid=2000(shell)'))"
  exit 0
fi

echo "❌ 接続できませんでした。以下を確認してください：設定 → デベロッパー向けオプション → ワイヤレスデバッグが有効になっているか"
exit 1
