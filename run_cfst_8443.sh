#!/usr/bin/env sh
set -eu

# IP 池来源与测速参数
IP_URL="https://v4.gh-proxy.org/https://raw.githubusercontent.com/LeibNici/Profile/refs/heads/master/domainIp.txt"
IP_FILE="ip.txt"
CFST_DIR="${1:-$(pwd)}"
THREADS=20
PING_TIMES=8
DOWNLOAD_COUNT=20
DOWNLOAD_TIME=8
TEST_PORT=8443
MAX_LOSS_RATE=0.1

# 历史记录与优选结果
HISTORY_DIR="history"
HISTORY_KEEP=10
MIN_HISTORY_RUNS=3
BEST_COUNT=3
RESULT_FILE="result.csv"
BEST_CSV="best_ips.csv"
BEST_FILE="best_ips.txt"

cd "$CFST_DIR"
export LC_ALL=C

if [ ! -x "./cfst" ]; then
  echo "错误：当前目录没有可执行的 ./cfst"
  echo "请在 cfst 所在目录运行本脚本，或把 cfst 所在目录作为第一个参数传入。"
  echo "同时确认已执行：chmod +x cfst"
  exit 1
fi

# 防止 cron 与手动执行同时覆盖 result.csv 或历史记录。
LOCK_DIR=".run_cfst_8443.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "错误：已有一次测速正在进行。"
  exit 1
fi

TMP_FILE="${IP_FILE}.tmp.$$"
SUMMARY_TMP="${HISTORY_DIR}/.summary.$$"
trap 'rm -f "$TMP_FILE" "$SUMMARY_TMP"; rmdir "$LOCK_DIR" 2>/dev/null || true' 0 HUP INT TERM

echo "正在下载 IP 池..."
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
echo "开始测速：延迟 $PING_TIMES 次，下载测速前 $DOWNLOAD_COUNT 个候选 IP。"
./cfst -f "$IP_FILE" -n "$THREADS" -t "$PING_TIMES" \
  -dn "$DOWNLOAD_COUNT" -dt "$DOWNLOAD_TIME" -tp "$TEST_PORT" \
  -tlr "$MAX_LOSS_RATE" -o "$RESULT_FILE" -p "$BEST_COUNT"

if [ ! -s "$RESULT_FILE" ]; then
  echo "错误：cfst 未生成有效的 $RESULT_FILE。"
  exit 1
fi

mkdir -p "$HISTORY_DIR"
RUN_FILE="$HISTORY_DIR/result-$(date +%Y%m%d-%H%M%S)-$$.csv"
cp "$RESULT_FILE" "$RUN_FILE"

# 归档文件名按时间排序，删除最旧记录，只保留最近 10 次。
set -- "$HISTORY_DIR"/result-*.csv
if [ "$1" != "$HISTORY_DIR/result-*.csv" ]; then
  history_count=$#
  while [ "$history_count" -gt "$HISTORY_KEEP" ]; do
    rm -f "$1"
    shift
    history_count=$((history_count - 1))
  done
fi

# 仅把下载速度大于 0 的行纳入速度统计；其他 0.00 行通常只完成了延迟测速。
# 候选 IP 须在历史中出现至少 3 轮，并至少有 3 次有效下载测速。
awk -F, -v min_runs="$MIN_HISTORY_RUNS" '
  FNR == 1 { history_files++; next }
  NF >= 6 && $1 ~ /^[0-9]+\./ {
    ip = $1
    runs[ip]++
    latency_sum[ip] += $5 + 0
    loss_sum[ip] += $4 + 0
    speed = $6 + 0
    if (speed > 0) {
      sample = ++speed_count[ip]
      speed_value[ip SUBSEP sample] = speed
      speed_sum[ip] += speed
      speed_sum_square[ip] += speed * speed
    }
  }
  END {
    for (ip in runs) {
      samples = speed_count[ip]
      if (runs[ip] < min_runs || samples < min_runs) continue

      for (i = 1; i <= samples; i++) ordered[i] = speed_value[ip SUBSEP i]
      for (i = 2; i <= samples; i++) {
        value = ordered[i]
        j = i - 1
        while (j >= 1 && ordered[j] > value) {
          ordered[j + 1] = ordered[j]
          j--
        }
        ordered[j + 1] = value
      }

      if (samples % 2) median = ordered[(samples + 1) / 2]
      else median = (ordered[samples / 2] + ordered[samples / 2 + 1]) / 2

      average = speed_sum[ip] / samples
      variance = speed_sum_square[ip] / samples - average * average
      if (variance < 0) variance = 0
      cv = (average > 0) ? sqrt(variance) / average : 999

      # 速度中位数为主；出现轮数越多、速度波动越小，评分越高。
      score = median * (0.70 + 0.30 * runs[ip] / history_files) / (1 + cv)
      printf "%s,%d,%d,%.2f,%.2f,%.2f,%.3f,%.2f,%.2f,%.3f\n", \
        ip, runs[ip], samples, median, average, ordered[1], cv, \
        latency_sum[ip] / runs[ip], loss_sum[ip] / runs[ip], score
    }
  }
' "$HISTORY_DIR"/result-*.csv > "$SUMMARY_TMP"

{
  echo "IP,出现轮数,有效下载次数,速度中位数(MB/s),平均速度(MB/s),最低速度(MB/s),速度波动系数,平均延迟(ms),平均丢包率,稳定性评分"
  sort -t, -k10,10nr "$SUMMARY_TMP"
} > "$BEST_CSV"

if [ -s "$SUMMARY_TMP" ]; then
  # best_ips.txt 与 best_ips.csv 保持相同的评分排序。
  awk -F, -v count="$BEST_COUNT" 'NR > 1 && NR <= count + 1 { print $1 }' "$BEST_CSV" > "$BEST_FILE"
  echo "已基于历史稳定性生成 $BEST_FILE（前 $BEST_COUNT 个）。"
else
  # 还未积累足够历史时，临时使用本轮最快的真实下载测速结果。
  awk -F, -v count="$BEST_COUNT" 'NR > 1 && $6 + 0 > 0 { print $1; found++; if (found == count) exit }' "$RESULT_FILE" > "$BEST_FILE"
  echo "历史样本不足（需至少 $MIN_HISTORY_RUNS 次），$BEST_FILE 暂使用本轮最快结果。"
fi

echo "本轮结果：$RESULT_FILE"
echo "历史记录：$RUN_FILE（最多保留 $HISTORY_KEEP 次）"
echo "历史汇总：$BEST_CSV"
echo "优选 IP：$BEST_FILE"
