#!/usr/bin/env sh
set -eu

IP_URL="https://v4.gh-proxy.org/https://raw.githubusercontent.com/LeibNici/Profile/refs/heads/master/domainIp.txt"
IP_FILE="ip.txt"
CFST_DIR="${1:-$(pwd)}"

cd "$CFST_DIR"

if [ ! -x "./cfst" ]; then
  echo "错误：当前目录没有可执行的 ./cfst"
  echo "请在 cfst 所在目录运行本脚本，或把 cfst 所在目录作为第一个参数传入。"
  echo "同时确认已执行：chmod +x cfst"
  exit 1
fi

echo "正在下载 IP 池..."
TMP_FILE="${IP_FILE}.tmp"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$IP_URL" -o "$TMP_FILE"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP_FILE" "$IP_URL"
else
  echo "错误：找不到 curl 或 wget，请先安装其中一个。"
  exit 1
fi

tr -s '[:space:]' '\n' < "$TMP_FILE" | sed '/^$/d' > "$IP_FILE"
rm -f "$TMP_FILE"

if [ ! -s "$IP_FILE" ]; then
  echo "错误：下载到的 $IP_FILE 为空。"
  exit 1
fi

if ! grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' "$IP_FILE"; then
  echo "错误：$IP_FILE 里没有识别到 IPv4，可能下载到了错误页面。"
  exit 1
fi

echo "IP 池已保存到 $IP_FILE"
echo "开始执行：./cfst -f $IP_FILE -t 50 -tp 8443"
./cfst -f "$IP_FILE" -t 50 -tp 8443
