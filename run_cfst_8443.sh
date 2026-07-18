#!/usr/bin/env sh
set -eu

IP_URL="https://bestcf.pages.dev/uouin/all.txt"
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

# BestCF 的每行格式为 "IP:端口#说明"。提取全部有效 IPv4，
# 丢弃端口和说明文字，并去重后交给 cfst 测速。
awk '
  {
    ip = $0
    sub(/:.*/, "", ip)
    count = split(ip, octet, ".")
    valid = (count == 4)
    for (i = 1; i <= 4 && valid; i++) {
      if (octet[i] !~ /^[0-9]+$/ || octet[i] > 255) valid = 0
    }
    if (valid && !seen[ip]++) print ip
  }
' "$TMP_FILE" > "$IP_FILE"
rm -f "$TMP_FILE"

if [ ! -s "$IP_FILE" ]; then
  echo "错误：下载到的 $IP_FILE 为空。"
  exit 1
fi

if ! grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' "$IP_FILE"; then
  echo "错误：$IP_FILE 里没有可供 cfst 测速的 IP，可能下载到了错误页面。"
  exit 1
fi

echo "IP 池已保存到 $IP_FILE"
echo "开始执行：./cfst -f $IP_FILE -n 20 -t 10 -tp 8443 -httping -tlr 0.1"
./cfst -f "$IP_FILE" -n 20 -t 10 -tp 8443 -httping -tlr 0.1
