#!/bin/bash
#
# access-log-digest.sh - 前日分のアクセスログから要点をダイジェスト化し、
#                        前回との差分を出力する。cron で日次実行する想定。
#
# 設置例:
#   install -m 755 scripts/access-log-digest.sh /usr/local/bin/access-log-digest.sh
#
# cron 例(毎朝 6:05 に前日分の差分をメール):
#   5 6 * * * /usr/local/bin/access-log-digest.sh | mail -s "access log digest $(hostname)" you@example.com
#
set -euo pipefail

LOG="${LOG:-/var/log/nginx/access.log.1}"   # logrotate 直後に回すので前日分を見る
OUT="${OUT:-/var/backups/access-digest}"
install -d -m 700 "$OUT"
today=$(date +%F)

{
  echo "== 404を出しているIP 上位10 =="
  awk '$9==404 {print $1}' "$LOG" | sort | uniq -c | sort -rn | head -10
  echo "== 2xxで返っている要注意パス(空であること) =="
  awk '$9 ~ /^2/ && $7 ~ /\.env|\.git|\.bak|\.sql|wp-config|phpinfo/ {print $7}' "$LOG" \
    | sort | uniq -c | sort -rn | head -10
} > "$OUT/$today.txt"

# 直前のダイジェストとの差分だけを出す(増えた行があるときだけ元ログを開くのがコツ)。
prev=$(ls -1 "$OUT"/*.txt | tail -2 | head -1)
[ "$prev" = "$OUT/$today.txt" ] || diff -u "$prev" "$OUT/$today.txt" || true
