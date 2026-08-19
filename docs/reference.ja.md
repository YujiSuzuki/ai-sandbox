# リファレンス

[English version here](reference.md)

環境設定、オプション、トラブルシューティングなどの補足情報です。

[← README に戻る](../README.ja.md)

---

## 2つの環境

| 環境 | 用途 | 使用タイミング |
|-------------|---------|-------------|
| **DevContainer** (`.devcontainer/`) | VS Codeでの主要開発 | 日常的な開発 |
| **CLI Sandbox** (`cli_sandbox/`) | 代替/復旧 | DevContainerが壊れた時 |

**なぜ2つの環境？**

**復旧用の代替環境** として重要です。

Dev Container の設定が壊れた場合：
1. VS Code で Dev Container が起動できない
2. Claude Code も動かない
3. 設定を直すのに AI の助けを借りられない → **詰む**

`cli_sandbox/` があれば：
1. Dev Container が壊れても
2. ホストから AI を起動できる
   - `./cli_sandbox/claude.sh` (Claude Code)
   - `./cli_sandbox/gemini.sh` (Gemini CLI)
3. AI に Dev Container の設定を直してもらえる

```bash
./cli_sandbox/claude.sh   # または
./cli_sandbox/gemini.sh
# 壊れたDevContainer設定をAIに修正してもらう
```

---

## プロジェクト名のカスタマイズ

デフォルトでは、DevContainer のプロジェクト名は `<親ディレクトリ名>_devcontainer`（例：`workspace_devcontainer`）になります。

カスタムのプロジェクト名を設定するには、`.devcontainer/.env` ファイルを作成します：

```bash
# .env.example をコピー
cp .devcontainer/.env.example .devcontainer/.env
```

`.env` ファイルの内容：
```bash
COMPOSE_PROJECT_NAME=ai-sandbox
```

これにより、コンテナ名やボリューム名がより分かりやすくなります：
- コンテナ: `ai-sandbox-ai-sandbox-1`
- ボリューム: `ai-sandbox_node-home`

> **注意:** `.env` ファイルは `.gitignore` に追加されているため、各開発者が自分用の設定を持てます。

---

## 起動時の自動検証

DevContainer と CLI Sandbox は、起動するたびに以下の検証を自動実行します：

| チェック内容 | やっていること |
|-------------|--------------|
| AI設定のマージ | サブプロジェクトの `.claude/settings.json` を自動統合 |
| 設定の整合性 | DevContainer と CLI Sandbox で秘匿設定にズレがないか確認 |
| 秘匿ファイルの隠蔽 | `.env` や `secrets/` が実際にAIから見えなくなっているか検証 |
| 同期チェック | AI設定でブロックしたファイルが docker-compose でも隠されているか確認 |
| テンプレート更新 | 新しいバージョンのテンプレートがあれば通知 |

問題が見つかった場合は警告が表示され、ユーザーが確認してから続行できます。<ins>設定ミスに気づかないまま作業してしまう心配がありません。</ins>

### 出力オプション

検証結果の表示量を制御できます：

| モード | フラグ | 出力内容 |
|--------|--------|----------|
| Quiet | `--quiet` または `-q` | 警告とエラーのみ（最小限） |
| Summary | `--summary` または `-s` | 簡潔なサマリー |
| Verbose | (なし、デフォルト) | 罫線装飾付きの詳細出力 |

**CLI Sandbox の例：**
```bash
# 最小限の出力（警告のみ）
./cli_sandbox/ai_sandbox.sh --quiet

# 簡潔なサマリー
./cli_sandbox/ai_sandbox.sh --summary
```

**環境変数：**
```bash
# デフォルトの詳細度を設定
export STARTUP_VERBOSITY=quiet  # または: summary, verbose
```

**設定ファイル:** `.sandbox/config/startup.conf`
```bash
# 全起動スクリプトのデフォルト詳細度
STARTUP_VERBOSITY="verbose"

# "詳細はREADMEを参照"メッセージで使用するURL
README_URL="README.md"
README_URL_JA="README.ja.md"  # LANG=ja_JP* の場合に使用

# ラベルごとのバックアップ保持件数（0 = 無制限）
BACKUP_KEEP_COUNT=0
```

sync スクリプトが作成するバックアップは `.sandbox/backups/` に保存されます。保持件数を制限するには：

```bash
# 直近10件のみ保持
BACKUP_KEEP_COUNT=10

# 環境変数で一時的に上書きも可能
BACKUP_KEEP_COUNT=10 .sandbox/scripts/sync-secrets.py
```

---

## 同期警告からのファイル除外

起動スクリプトは `.claude/settings.json` でブロックされたファイルが `docker-compose.yml` でも隠蔽されているかチェックします。特定のパターン（`.example` ファイルなど）を警告から除外するには、`.sandbox/config/sync-ignore` を編集します：

```gitignore
# example/template ファイルを同期警告から除外
**/*.example
**/*.sample
**/*.template
```

これは gitignore 形式のパターンを使用します。これらのパターンにマッチするファイルは「docker-compose.yml に未設定」警告をトリガーしません。

---

## 複数のDevContainerを起動する場合

完全に分離したDevContainer環境が必要な場合（例：異なるクライアント案件）、`COMPOSE_PROJECT_NAME` を使って分離したインスタンスを作成できます。

<details>
<summary>方法とホームディレクトリの共有</summary>

### 方法A: .env ファイルで分離（推奨）

`.devcontainer/.env` で異なるプロジェクト名を設定：

```bash
COMPOSE_PROJECT_NAME=client-a
```

別のワークスペースでは：

```bash
COMPOSE_PROJECT_NAME=client-b
```

### 方法B: コマンドラインで分離

異なるプロジェクト名でDevContainerを起動：

```bash
# プロジェクトA
COMPOSE_PROJECT_NAME=client-a docker-compose up -d

# プロジェクトB（別のボリュームが作成される）
COMPOSE_PROJECT_NAME=client-b docker-compose up -d
```

> ⚠️ **注意:** プロジェクト名が異なるとボリュームも別になるため、ホームディレクトリ（認証情報・設定・履歴）は自動的に共有されません。下記「ホームディレクトリのコピー」を参照。

### 方法C: バインドマウントでホームディレクトリを共有

全インスタンスでホームディレクトリを自動共有したい場合、`docker-compose.yml` をバインドマウントに変更：

```yaml
volumes:
  # 名前付きボリュームの代わりにバインドマウント
  - ~/.ai-sandbox/home:/home/node
  - ~/.ai-sandbox/gcloud:/home/node/.config/gcloud
```

**メリット:**
- 全インスタンスでホームディレクトリを自動共有
- バックアップが簡単（ホストディレクトリをコピーするだけ）

**デメリット:**
- ホストのディレクトリ構造に依存
- Linuxホストでは UID/GID の調整が必要な場合あり

### ホームディレクトリのエクスポート/インポート

ホームディレクトリ（認証情報・設定・履歴）をバックアップまたは別のワークスペースに移行できます：

```bash
# ワークスペース全体をエクスポート（devcontainer と cli_sandbox の両方）
./.sandbox/host-tools/copy-credentials.sh --export /path/to/workspace ~/backup

# 特定の docker-compose.yml からエクスポート
./.sandbox/host-tools/copy-credentials.sh --export .devcontainer/docker-compose.yml ~/backup

# ワークスペースにインポート
./.sandbox/host-tools/copy-credentials.sh --import ~/backup /path/to/workspace
```

**注意:** インポート先のボリュームが存在しない場合、先に環境を一度起動してボリュームを作成する必要があります。

用途：
- `~/.claude/` の使用量データを確認
- 設定のバックアップ
- 新しいワークスペースへの認証情報の移行
- トラブルシューティング

</details>

---

## HostMCPのアンインストール

HostMCPが不要になった場合、インストール先に応じてバイナリを削除します：

```bash
rm ~/go/bin/hostmcp
# または
rm /usr/local/bin/hostmcp
```

---

## トラブルシューティング

### HostMCP接続

Claude CodeがHostMCPツールを認識しない場合：

1. **VS Codeのポートパネルを確認** - HostMCPのポート（デフォルトでは18080）がフォワードされていたら停止
2. **HostMCPが実行中か確認** - `curl http://localhost:18080/health`（ホストOS上で）
3. **MCP再接続を試す** - Claude Codeで `/mcp` を実行し、「Reconnect」を選択
4. **VS Codeを完全に再起動**（Cmd+Q / Alt+F4）- Reconnectで解決しない場合

### macOS: hostmcp が起動できない（"Killed: 9"）

`hostmcp version`（や他の `hostmcp` コマンド）が即座に `Killed: 9` で終了する場合、実際に再現確認した限り最も多い原因は、**`hostmcp serve` プロセスが同じバイナリファイルを使い続けている状態で、その `hostmcp` バイナリを上書きしてしまうこと**です。実行中のプロセスは現在のバイナリのコードをマップし続けています。そこに同じファイルへ直接上書き（例えば既存パスへの `cp`）を行うと、実行中プロセスの足元でディスク上のバイト列が変わってしまい、macOS のコード整合性検証がこれを検知して、新しいバイナリを起動しようとしたプロセスを強制終了させます。実際に、`hostmcp serve` を動かしたまま新しいバイナリを `cp` で上書きすると毎回 `Killed: 9` になり、`serve` を停止すると直る、という挙動を繰り返し再現できました。

これは macOS のコード署名の仕組みそのものと一致します：署名情報はファイルのカーネル内 vnode に紐づいてキャッシュされており、その vnode が使用中のままファイルの中身を書き換えるとキャッシュが無効になります。回避するには、本当に新しいファイル（新しい vnode/inode）を用意し、アトミックな rename で差し替える必要があります（Apple Developer Forums「Signing modified binaries」参照）。

`install-hostmcp.sh` は、インストール先に直接書き込むのではなく、**一時ファイルにダウンロードしてからアトミックに配置（rename）する**ことでこの問題を回避しています。実際に `hostmcp serve` を動かしたまま更新しても問題なく動作することを確認済みです。`go install` も同様に安全です：Go のツールチェーンはビルド成果物を新しいファイルに書き出してから rename する（フォールバック経路でも、既存ファイルを unlink してから新規作成する）ため、その場での上書きにはなりません。rename方式でない別の方法（例えば手動での `cp` によるバイナリ差し替え）を使う場合は、**先に実行中の `hostmcp serve` を停止**してからバイナリを置き換え、その後で再起動してください。

(再)インストール中に `hostmcp serve` が動いていなかったことを確認した上でまだ `hostmcp version` が起動に失敗する場合は、Gatekeeper・署名関連が別の要因として関わっている可能性があります。以下で確認できます：
```bash
spctl -a -vvv $(which hostmcp)
# "rejected" と出れば Gatekeeper・署名が関係しています
```
明示的に信頼させることで解決します：
```bash
sudo spctl --add --label hostmcp $(which hostmcp)
```
またはGUIで：システム設定 → プライバシーとセキュリティ → hostmcp の警告の横にある「このまま開く」をクリック。

### setup-hostmcp.py による自動セットアップ

AI Sandbox 内でセットアップスクリプトを使うと、HostMCP の登録状態の確認や自動登録ができます：

```bash
# 現在の状態を確認（サイレント、スクリプト連携向き）
.sandbox/scripts/setup-hostmcp.py --check
# 終了コード: 0 = 接続済み, 1 = 未登録, 2 = 登録済みだがオフライン

# 人向けのステータス表示
.sandbox/scripts/setup-hostmcp.py --status

# 検出した AI ツールに HostMCP を登録 + 接続確認
.sandbox/scripts/setup-hostmcp.py

# カスタム URL を指定（デフォルトは .sandbox/config/hostmcp.yaml の server.port から自動検出）
.sandbox/scripts/setup-hostmcp.py --url http://host.docker.internal:9090/sse

# 全 AI ツールから HostMCP の登録を解除
.sandbox/scripts/setup-hostmcp.py --unregister
```

スクリプトは利用可能な AI ツール（Claude Code, Gemini CLI）を自動検出し、HostMCP を SSE MCP サーバーとして登録します。登録後は、スクリプトが表示する「次のステップ」に従ってください（例：Claude Code で `/mcp` → Reconnect）。

### フォールバック：AI Sandbox内でhostmcp clientを使用

MCPプロトコルが動作しない場合（Claude CodeやGeminiが接続できない）、フォールバックとしてAI Sandbox内で `hostmcp client` コマンドを直接使用できます。

> **注意:** `/mcp` で「✔ connected」と表示されていても、MCPツールが「Client not initialized」エラーで失敗することがあります。これはVS Code拡張機能（Claude Code, Gemini Code Assist等）のセッション管理のタイミング問題が原因である可能性があります。この場合：
> 1. まず `/mcp` → 「Reconnect」を試す（簡単な解決策）
> 2. それでも解決しない場合、AIは `hostmcp client` コマンドをフォールバックとして使用
> 3. 最終手段として、VS Codeを完全に再起動して接続を再確立

**セットアップ:** 自動です。コンテナ起動時に `startup.sh` が `hostmcp` CLI をインストールします（Go が使える場合は `go install`、そうでなければ GitHub Releases からビルド済みバイナリをダウンロード）。手動操作は不要です。

何らかの理由で入っていない場合は、手動でインストールしてください：
```bash
go install github.com/YujiSuzuki/hostmcp@latest
```

**使用方法:**
```bash
# コンテナ一覧
hostmcp client list

# ログ取得
hostmcp client logs securenote-api

# コマンド実行
hostmcp client exec securenote-api "npm test"
```

> **`--url` について:** 可能な場合は `hostmcp.yaml` の `server.port` から自動検出します（それ以外は `http://host.docker.internal:18080`）。必要に応じて `--url` フラグまたは環境変数 `HOSTMCP_SERVER_URL` で上書きできます。
> ```bash
> hostmcp client list --url http://host.docker.internal:9090
> # または
> export HOSTMCP_SERVER_URL=http://host.docker.internal:9090
> ```
