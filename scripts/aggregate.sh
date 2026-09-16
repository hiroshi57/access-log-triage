#!/bin/bash
#
# aggregate.sh - アクセスログ(combined 形式)を 7 本の集計に通して
#                「見るべき数行」まで絞り込む。nginx / Apache 共通。
#
# 使い方:
#   LOGS="/var/log/nginx/access.log /var/log/nginx/access.log.1 /var/log/nginx/access.log.*.gz" \
#     bash scripts/aggregate.sh
#
# Apache の場合の LOGS 例:
#   LOGS="/var/log/apache2/access.log*"          # Debian/Ubuntu
#   LOGS="/var/log/httpd/access_log*"            # RHEL 系
#
# combined 形式のフィールド:
#   $1=送信元IP  $6=メソッド(先頭に ")  $7=パス  $9=ステータス  $10=応答サイズ
#
set -euo pipefail

# 対象ログ。未指定なら nginx の既定を見る。
LOGS="${LOGS:-/var/log/nginx/access.log /var/log/nginx/access.log.1 /var/log/nginx/access.log.*.gz}"

# zcat -f は非圧縮ファイルもそのまま流すので .gz と生ログを混ぜて渡せる。
# shellcheck disable=SC2086
cat_logs() { zcat -f $LOGS; }

echo "== 対象行数 =="
cat_logs | wc -l
echo

echo "== 集計1: 送信元 IP の上位20 =="
cat_logs | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
echo

echo "== 集計2: ログイン系(wp-login.php / xmlrpc.php)への POST 上位20 =="
cat_logs | awk '$6=="\"POST" && $7 ~ /wp-login\.php|xmlrpc\.php/ {print $1}' \
  | sort | uniq -c | sort -rn | head -20
echo

echo "== 集計3: 404 を量産している IP 上位20 =="
cat_logs | awk '$9==404 {print $1}' | sort | uniq -c | sort -rn | head -20
echo

echo "== 集計4: 何を探されているか(404 のパス) 上位30 =="
cat_logs | awk '$9==404 {print $7}' | sed 's/?.*//' \
  | sort | uniq -c | sort -rn | head -30
echo

echo "== 集計5: 2xx で返ってしまっている要注意パス(最重要・空であること) =="
cat_logs | awk '$9 ~ /^2/ && $7 ~ /\.env|\.git|\.bak|\.old|\.sql|\.zip|wp-config|phpinfo|adminer|phpmyadmin|\.DS_Store/ {print $7}' \
  | sed 's/?.*//' | sort | uniq -c | sort -rn | head -30
echo

echo "== 集計6: 転送量の多い送信元 上位20 =="
cat_logs | awk '$9 ~ /^2/ {b[$1]+=$10} END {for (i in b) printf "%15.0f  %s\n", b[i], i}' \
  | sort -rn | head -20
echo

echo "== 集計7: User-Agent の偏り 上位20 =="
cat_logs | awk -F'"' '{print $6}' | sort | uniq -c | sort -rn | head -20
