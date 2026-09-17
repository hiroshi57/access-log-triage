# access-log-triage

Web サーバのアクセスログ（nginx / Apache の combined 形式）を **7 本のコマンドに通して「見るべき数行」まで絞り込み**、見つけた攻撃元を **fail2ban で自動遮断**するための実用ツールキットです。

サーバに SSH で入れる Web 担当者・サイト運営者・制作会社向け。生ログを `tail` で眺めても、1 日数万行から異常だけを拾うのは無理です。このリポジトリは「攻撃されていませんか？」に**ログで答える**ための最小セットをまとめています。

> **出典 / クレジット**
> 本リポジトリは以下の記事の内容を要約・スクリプト化したものです。解説の全文は原典を参照してください。
> [アクセスログから割り出す「アクセスの中身」を見抜く7つの集計（nginx/Apache対応・コピペOK）](https://qiita.com/jiis-sasaki/items/7affa2e2ef22ebf93fa6) — 著者: [@jiis-sasaki](https://qiita.com/jiis-sasaki)（Qiita）

---

## いちばん先にやること

### 手順 0: ログに「本当のクライアント IP」が入っているか確認する

Cloudflare・ロードバランサ・リバースプロキシ配下では、何もしないと記録されるのは**プロキシの IP** です。上位が全部同じ IP になり、そのまま fail2ban に食わせると**自サイトの入口ごと遮断**してしまいます。

```bash
tail -1 /var/log/nginx/access.log
```

先頭アドレスが訪問者ではなく CDN / LB のものなら、IP 復元設定が必要です。

- nginx → [`config/nginx-realip.conf`](config/nginx-realip.conf)（realip モジュール）
- Apache → [`config/apache-remoteip.conf`](config/apache-remoteip.conf)（mod_remoteip）

反映後、自分の回線でサイトを開き `tail -1` に自分の IP が出れば準備完了です。

---

## 7 つの集計

combined 形式は nginx / Apache でフィールド位置が同じなので、同じ awk がそのまま使えます。すべての集計を 1 本にまとめたのが [`scripts/aggregate.sh`](scripts/aggregate.sh) です。

```bash
# 対象ログ（ローテート済み・.gz 込み）をまとめて解析
LOGS="/var/log/nginx/access.log /var/log/nginx/access.log.1 /var/log/nginx/access.log.*.gz" \
  bash scripts/aggregate.sh
```

| # | 集計 | 何が分かるか |
|---|------|-------------|
| 1 | 送信元 IP の上位 | 全体像。知らない IP が桁違いで 1 位なら以降で中身を見る |
| 2 | ログイン系（`wp-login.php` / `xmlrpc.php`）への POST | 1 IP から数百〜数千回なら総当たり。`xmlrpc` は本来 0 件 |
| 3 | 404 を量産している IP | 脆弱性スキャナの動き |
| 4 | 何を探されているか（404 のパス一覧） | 「絶対に 200 を返してはいけないパス」の一覧でもある |
| 5 | **2xx で返ってしまっている要注意パス（最重要）** | 出たら「攻撃されている」ではなく**「すでに取られた」** |
| 6 | 転送量の多い送信元 | 大量取得・ファイル持ち出しの可能性 |
| 7 | User-Agent の偏り | ツール名や空 `-` が上位なら要注意（単独の根拠にはしない） |

### 集計 5 だけは意味が違う

`.env` / `.git` / `.bak` / `wp-config` / `phpinfo` などが **2xx で配信された記録**が 1 行でも出たら、バックアップや環境変数ファイルが実際に流出したということです。**遮断より先に、対象ファイルの削除と、そこに書かれていた認証情報の変更**が必要です。出力が空であることを確認するのがゴール。

まずはここを 1 回流すところから始めてください。

### 実行例：サンプルログで「読み方」をつかむ

次のような 6 行のログがあったとします（`$1`=IP、`$6`=メソッド、`$7`=パス、`$9`=ステータス、`$10`=サイズ）。

```text
203.0.113.10 - - [10/Sep/2026:07:12:33 +0900] "POST /wp-login.php HTTP/1.1" 200 1234 "-" "curl/8.5.0"
203.0.113.10 - - [10/Sep/2026:07:12:34 +0900] "POST /wp-login.php HTTP/1.1" 200 1234 "-" "curl/8.5.0"
198.51.100.5 - - [10/Sep/2026:07:13:00 +0900] "GET /.env HTTP/1.1" 200 512 "-" "Mozilla/5.0"
198.51.100.5 - - [10/Sep/2026:07:13:01 +0900] "GET /wp-config.php.bak HTTP/1.1" 404 0 "-" "Mozilla/5.0"
198.51.100.5 - - [10/Sep/2026:07:13:02 +0900] "GET /phpinfo.php HTTP/1.1" 404 0 "-" "sqlmap"
192.0.2.1 - - [10/Sep/2026:07:14:00 +0900] "GET /index.html HTTP/1.1" 200 8000 "-" "Mozilla/5.0"
```

`LOGS=/path/to/sample.log bash scripts/aggregate.sh` の出力（抜粋）と読み方：

```text
== 集計2: ログイン系(wp-login.php / xmlrpc.php)への POST 上位20 ==
      2 203.0.113.10          ← wp-login.php に POST を連打。総当たりの常連。fail2ban 対象
== 集計3: 404 を量産している IP 上位20 ==
      2 198.51.100.5          ← 存在しないパスを片端から叩く。脆弱性スキャナの動き
== 集計4: 何を探されているか(404 のパス) 上位30 ==
      1 /wp-config.php.bak    ← 「200 を返してはいけないパス」一覧。設定確認に使う
      1 /phpinfo.php
== 集計5: 2xx で返ってしまっている要注意パス(最重要・空であること) ==
      1 /.env                 ← ★ これが最悪。/.env が 200 で配信済み = 環境変数が流出
== 集計7: User-Agent の偏り 上位20 ==
      1 sqlmap                ← 明らかな攻撃ツール名（ただし UA は詐称可能なので単独判断はしない）
```

**この例での動き方**：

1. 集計 5 に `/.env` が出た → **最優先で対応**。`.env` ファイルを削除し、そこに書かれていた DB パスワード・API キー・認証情報を**すべて再発行**する（遮断より先）。
2. 集計 2 の `203.0.113.10` → ログイン総当たりの常連。`fail2ban/` の設定で自動遮断へ。
3. 集計 3・4 の `198.51.100.5` → スキャナ。`/.env` `/phpinfo.php` などに 200 を返さない設定（アクセス制限）を確認。

> 実運用では 1 位が数千〜数万リクエストになります。桁が 1 つ飛び抜けている行だけを追えば十分です。

---

## 日次で回す（差分だけ見る）

手で叩くのは最初の 1 回だけ。あとは日次で回し、**前日との差分だけ**を見ます。

- [`scripts/access-log-digest.sh`](scripts/access-log-digest.sh) … 前日分のダイジェストを生成し、前回との差分を出力
- cron 例（毎朝 6:05 にメール）:

```cron
5 6 * * * /usr/local/bin/access-log-digest.sh | mail -s "access log digest $(hostname)" you@example.com
```

毎日全文を読む運用は続きません。増えた行があるときだけ元ログを開くのがコツです。

**差分の読み方の例**（前日→当日で `diff -u` が出す形）：

```diff
 == 404を出しているIP 上位10 ==
       2 198.51.100.5
+     87 45.146.164.110      ← 昨日いなかった IP が急に 87 件。新しいスキャナが来た合図
 == 2xxで返っている要注意パス(空であること) ==
+      1 /.git/config        ← ★ 昨日まで空だったのに 1 行増えた。即対応
```

`+` の行（＝昨日から増えた分）だけ見れば、その日に何が起きたかが分かります。差分が空の日はメールが空 or 変化なし。増えた日だけ元ログを開きます。

---

## 見つけた相手を fail2ban で遮断する

同梱の nginx 系 jail はいずれも**エラーログ**を見ます。`wp-login.php` への POST は**アクセスログ**にしか出ないので、フィルタを 1 つ自作します。

- [`fail2ban/filter.d/wordpress-auth.conf`](fail2ban/filter.d/wordpress-auth.conf)
- [`fail2ban/jail.local`](fail2ban/jail.local)

反映前に、必ず実ログでフィルタが当たるか確認します（BAN はしない）:

```bash
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wordpress-auth.conf
fail2ban-client reload
fail2ban-client status wordpress-auth              # 現在の BAN 一覧
fail2ban-client set wordpress-auth unbanip 203.0.113.10   # 誤爆の解除
```

`fail2ban-regex` の出力例（`Matched` が 0 のままなら正規表現かログパスがずれている）：

```text
Results
=======
Failregex: 342 total
|-  #) [# of hits] regular expression
|   1) [342] ^<HOST> .* "POST [^"]*/(wp-login\.php|xmlrpc\.php)
`-

Lines: 51234 lines, 0 ignored, 342 matched, 50892 missed
```

`status` の出力例（`203.0.113.10` が実際に BAN された状態）：

```text
Status for the jail: wordpress-auth
|- Filter
|  |- Currently failed: 3
|  |- Total failed:     342
|  `- File list:        /var/log/nginx/access.log
`- Actions
   |- Currently banned: 1
   |- Total banned:     1
   `- Banned IP list:   203.0.113.10
```

### 誤爆させないための 3 点

1. **`ignoreip` に自社 IP・監視サービス・決済/予約 Webhook 送信元を先に入れる**。自分が締め出されるのが最も多い事故。
2. **リバースプロキシ配下では手順 0 を必ず先に**。復元していないと CDN の IP を BAN して全訪問者が落ちる。
3. **`maxretry` はいきなり絞らない**。数日 `bantime = 10m` で様子を見てから伸ばす。

> 遮断は更新の代わりにはなりません。BAN は反復を止めるだけで、脆弱性は残ったままです。

---

## ログが残っていない、という落とし穴

- **保持期間**: 侵入の発覚は数週間後が多い。`/etc/logrotate.d/nginx` の `rotate` を確認し、`compress` 併用で 90 日程度まで伸ばす。
- **バッファリング**: `access_log ... buffer=64k flush=5m;` だと直近の行はすぐ出ない。調査中は `flush` を意識。
- **ノイズ**: 死活監視で 1 日数万行が埋まるなら除外すると読みやすい（[`config/exclude-healthcheck.conf`](config/exclude-healthcheck.conf) 参照）。

---

## まとめ

1. 最初にログのクライアント IP が本物かを確認する（realip / mod_remoteip）
2. **集計 5（2xx の要注意パス）だけは意味が違う**。出たらファイル削除と認証情報変更を最優先
3. 日次ダイジェスト + 差分で回し、増えたときだけ元ログを開く
4. 常連は fail2ban へ。`ignoreip` を先に埋め、`fail2ban-regex` で当たりを確認してから有効化

ログは「攻撃されているか」だけでなく、**設定の穴が実際に踏まれたか**まで答えてくれる唯一の記録です。

---

## ライセンス

本リポジトリ内のスクリプト・設定ファイルは [MIT License](LICENSE) です。
解説文の著作権は原典記事の著者に帰属します。詳細な解説は必ず[原典](https://qiita.com/jiis-sasaki/items/7affa2e2ef22ebf93fa6)を参照してください。
