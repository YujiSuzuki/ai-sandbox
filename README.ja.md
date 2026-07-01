# AI Sandbox Environment + HostMCP + SandboxMCP

[English README is here](README.md)


AIコーディングエージェントは、プロジェクトディレクトリ内のすべてのファイルを読みます — `.env`、APIキー、秘密鍵も含めて。アプリケーションレベルのdenyルールで防げますが、設定ミスや[スコープの制限](docs/comparison.ja.md)に左右されます。もしシークレットがAIのファイルシステムに存在しなかったら？

このテンプレートは、Dockerベースで、機密情報をAIから物理的に隠しながらフル活用できる開発環境を作ります：

- **シークレットが物理的に存在しない** — `.env` や秘密鍵はAIのファイルシステムに存在しない。ルールでブロックするのではなく、そもそもない
- **設定ミスを自動検出** — 起動時にdenyルールとボリュームマウントの整合性をチェックし、隠し忘れがあればAIがアクセスする前に警告
- **コードは完全にアクセス可能** — 複数プロジェクトのソースコードをAIが読み書きできる
- **他のコンテナにもアクセスできる** — HostMCPを使えば、AIが別コンテナのログ確認やテスト実行を安全に行える
- **ヘルパースクリプトやツールを自動発見** — SandboxMCPにより、`.sandbox/` のスクリプトやツールをAIが自動で認識・実行
- **サンドボックスの外も操作できる** — ホストツールを承認すれば、`docker compose up` のようなホスト操作もAIに任せられる
- **コードレビューやテスト生成もコマンドひとつで** — 付属のスラッシュコマンドで、レビュー・リファクタ・テスト生成をAIに任せられる（Claude Code）


必要なものは **Docker** と **VS Code** だけ。[CLIだけでも使えます](docs/reference.ja.md#2つの環境)。

本プロジェクトはローカル開発環境での使用を想定しており、本番環境での使用は想定されていません。制約事項については「[制約事項](#制約事項)」と「[よくある質問](#よくある質問)」を参照してください。

> [!NOTE]
> **HostMCP** は、**ホスト OS** 上で動作するオプションの補助ツールです。サンドボックス内の AI に対して、Docker コンテナへのアクセス・ホストツールの実行・ホスト OS コマンドの実行など、ホスト環境への制御されたアクセスを提供します。[別リポジトリ](https://github.com/YujiSuzuki/hostmcp)として管理されており、独立してインストールします。これらの機能が不要な場合、このテンプレートは HostMCP なしでも動作します。
>
> **ホスト OS で動かす CLI ツール（Claude Code, Gemini CLI 等）での HostMCP 単体利用は非推奨です。** ホスト OS で動く CLI は `docker` コマンドやホストツールを直接実行できるため、HostMCP を経由するメリットがありません。一方、**Claude Desktop** のように MCP 経由でしか外部アクセスできないアプリでは、HostMCP 単体でもコンテナ操作やホストツール実行に有用です。スタンドアロンセットアップについては [HostMCP README](https://github.com/YujiSuzuki/hostmcp#readme) を参照してください。


---

# 目次

- [この環境が解決する実際の課題](#この環境が解決する実際の課題)
- [ユースケース](#ユースケース)
- [クイックスタート](#クイックスタート)
- [コマンド](#コマンド)
- [HostMCP ホストアクセス](#dockmcp-ホストアクセス)
- [AI SandBox 内部ツール](#ai-sandbox-内部ツール)
- [プロジェクト構造](#プロジェクト構造)
- [セキュリティ機能](#セキュリティ機能)
- [対応AIツール](#対応aiツール)
- [よくある質問](#よくある質問)
- [ドキュメント](#ドキュメント)


<details markdown="1">

<summary>📚 ドキュメントへのリンク（クリックで展開）</summary>

### 📖 はじめに
- [はじめてのセットアップガイド](docs/getting-started.ja.md) — ゼロから動く状態まで一歩ずつ案内
- [既存ソリューションとの比較](docs/comparison.ja.md) — Claude Code Sandbox、Docker AI Sandboxes等との比較
- [ハンズオン](docs/hands-on.ja.md) — セキュリティ機能を実際に体験する演習

### 🔧 セットアップ・運用
- [自分のプロジェクトへの適用](docs/customization.ja.md) — テンプレートのカスタマイズ手順
- [テンプレートの更新](docs/updating.ja.md) — 新しいリリースからの更新方法
- [リファレンス](docs/reference.ja.md) — 環境設定、オプション、トラブルシューティング

### 🏗️ アーキテクチャ
- [アーキテクチャ詳細](docs/architecture.ja.md) — セキュリティの仕組みと構成図
- [ネットワーク制限](docs/network-firewall.ja.md) — ファイアウォールの導入方法

### 📦 コンポーネント
- [HostMCP ドキュメント](https://github.com/YujiSuzuki/hostmcp#readme) — MCPサーバーの詳細
- [HostMCP ホストアクセス](docs/host-access.ja.md) — ホストツール、コンテナライフサイクル、ホストコマンド実行
- [HostMCP 設計思想](https://github.com/YujiSuzuki/hostmcp#design-philosophy) — 段階的アクセスモデルとAI・人の役割分担
- [プラグインガイド](docs/plugins.ja.md) — マルチリポ構成でのClaude Codeプラグイン活用
- [デモアプリガイド](https://github.com/YujiSuzuki/ai-sandbox-demo) — SecureNoteデモの実行方法（別リポジトリ）
- [CLI Sandbox ガイド](cli_sandbox/README.ja.md) — ターミナルベースのサンドボックス

</details>

----

# この環境が解決する実際の課題

**秘匿情報の保護** — ホストOSでAIを実行すると `.env` や秘密鍵へのアクセスを防ぐのが困難です。本環境ではAIをDockerコンテナに隔離し、**コードは見えるけど秘匿ファイルは見えない** 状態を作ります。

**複数プロジェクトの横断開発** — アプリとサーバーの連携部分の不具合調査は大変です。本環境は複数プロジェクトを1つのワークスペースにまとめ、AIがシステム全体を見渡せるようにします。

**コンテナ間の連携** — Sandbox化すると他のコンテナにアクセスできなくなりますが、HostMCPがこれを解消します。AIがAPIコンテナのログを読んだり、テストを実行したりできます。

> **既存ツールとの違いは？** Claude Code SandboxやDocker AI Sandboxesは有用なツールです。本プロジェクトはそれらを補完し、ファイルシステムレベルのシークレット隠蔽とコンテナ間アクセスを追加します。詳しくは [既存ソリューションとの比較](docs/comparison.ja.md) を参照してください。

## 制約事項

- **ローカル開発専用** — HostMCPには認証機能がないため、ローカル開発環境での使用を想定しています
- **Docker必須** — ボリュームマウントによるアプローチのため、Docker互換のランタイム（Docker Desktop、OrbStackなど）が必要です
- **macOSのみ検証済み** — Linux/Windowsでも動作する想定ですが、未検証です
- **ネットワーク制限なし（デフォルト）** — AIは外部HTTPリクエストを実行できます。ファイアウォールの追加は [ネットワーク制限ガイド](docs/network-firewall.ja.md) を参照してください
- **本番用シークレット管理の代替ではない** — 開発時の保護レイヤーです。本番環境ではHashiCorp Vault、AWS Secrets Manager等を使用してください


# ユースケース

### マイクロサービス開発
```
workspace/
├── mobile-app/     ← Flutter/React Native
├── api-gateway/    ← Node.js
├── auth-service/   ← Go
└── db-admin/       ← Python
```
APIキーを公開せずに、AIがすべてのサービスを横断してサポート。

### フルスタックプロジェクト
```
workspace/
├── frontend/       ← React
├── backend/        ← Django
└── workers/        ← Celeryタスク
```
AIがフロントエンドのコードを編集しながら、バックエンドのログを確認可能。

### レガシー + 新規
```
workspace/
├── legacy-php/     ← 古いコードベース
└── new-service/    ← モダンな書き直し
```
AIが両方を理解し、移行を支援。

---

# クイックスタート

## 前提条件

| 構成 | 必要なもの |
|------|-----------|
| **Sandbox（VS Code）** | Docker + VS Code + [Dev Containers拡張](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) |
| **Sandbox（CLIのみ）** | Docker のみ |
| **Sandbox + HostMCP** | 上記いずれか + [HostMCP](https://github.com/YujiSuzuki/hostmcp)（または `go install`）+ MCP対応AI CLI |

## しくみ（概要）

```
AI Sandbox（コンテナ）  →  HostMCP（ホストOS）  →  他のコンテナ（API, DB等）
   AIはここで動く            アクセスを中継           ログ確認・テスト実行
   秘匿ファイルは見えない     セキュリティポリシー適用
```

AIはDockerコンテナのSandbox内で動くため、秘匿ファイルはまるで存在しないかのようにアクセスできなくなります。それでも開発に支障はありません。HostMCPを通じて、AIは他のコンテナのログ確認やテスト実行ができるからです。

HostMCP とは別に **SandboxMCP** がコンテナ内で動作し、`.sandbox/` 内のスクリプトやツールをAIが自動的に認識・実行できるようにします。詳しくは [AI SandBox 内部ツール](#ai-sandbox-内部ツール) を参照。

→ 詳しい構成図は [アーキテクチャ詳細](docs/architecture.ja.md) を参照

> [!TIP]
> **💡 日本語環境にする場合:** DevContainer（または cli_sandbox）を開く前に、ホストOS上で以下を実行：
> ```bash
> .sandbox/host-setup/init-host-env.sh
> ```
> 言語選択で `2) 日本語` を選ぶと、コンテナ内のターミナル出力が日本語になります。
> （コンテナ内からでも実行できます）


## オプションA: Sandbox

秘匿情報の隠蔽だけでよい場合（HostMCPなし）：

```bash
# 1. VS Codeで開く
code .

# 2. コンテナで再度開く（Cmd+Shift+P / F1 → "Dev Containers: Reopen in Container"）
```

<details markdown="1">

<summary><code>code</code> コマンドが見つからない場合</summary>

**VS Codeのメニューから開く方法:**
「ファイル → フォルダーを開く」でこのフォルダーを選択してください。

**`code` コマンドをインストールする方法（macOS）:**
VS Code上でコマンドパレット（Cmd+Shift+P）を開き、`Shell Command: Install 'code' command in PATH` を実行してください。ターミナルを再起動すると `code` コマンドが使えるようになります。

> 参考: [Visual Studio Code on macOS - 公式ドキュメント](https://code.visualstudio.com/docs/setup/mac)

</details>

<details markdown="1">

<summary>CLI Sandbox 環境（ターミナルベース）の場合</summary>

```bash
   ./cli_sandbox/claude.sh # (Claude Code)
   ./cli_sandbox/gemini.sh # (Gemini CLI)
```

</details>

**これだけです！** AIは `/workspace` 内のコードにアクセスできますが、`.env` と `secrets/` ディレクトリは隠されています。


## オプションB: Sandbox + HostMCP

AIに他コンテナのログ確認やテスト実行もさせたい場合：

### ステップ1: HostMCP をインストールして起動（ホストOS上で）

```bash
# HostMCP をインストール（Go が必要 — https://go.dev/dl/ 参照）
go install github.com/YujiSuzuki/hostmcp@latest

# サンプル設定ファイルを取得
curl -L https://raw.githubusercontent.com/YujiSuzuki/hostmcp/main/configs/hostmcp.example.yaml -o hostmcp.yaml

# サーバーを起動
hostmcp serve --config hostmcp.yaml --sync
```

`--sync` フラグを付けると、起動時に[ホストツールの承認ワークフロー](#ホストツール)が実行され、付属のデモツールをすぐ AI に使わせることができます。ホストツールが不要なら省略可能です。

### ステップ2: DevContainerを開く

```bash
code .
# Cmd+Shift+P / F1 → "Dev Containers: Reopen in Container"
```

### ステップ3: HostMCPをMCPサーバーとして登録

AI Sandbox内のシェルで：

```bash
# Claude Code
claude mcp add --transport sse --scope user hostmcp http://host.docker.internal:18080/sse

# Gemini CLI
gemini mcp add --transport sse hostmcp http://host.docker.internal:18080/sse
```

Claude Codeの場合は `/mcp` → 「Reconnect」を実行してください。

> **重要:** HostMCPサーバーを再起動した場合も、再接続が必要です。

### ステップ4（推奨）: カスタムドメイン設定

```bash
# macOS/Linux — ホストOS上で実行
echo "127.0.0.1 securenote.test api.securenote.test" | sudo tee -a /etc/hosts
```

> AI Sandboxは `docker-compose.yml` の `extra_hosts` により、カスタムドメインを自動的に解決します。

### ステップ5（オプション）: デモアプリで試す

秘匿情報隠蔽と HostMCP の動作を体験できる SecureNote デモは、別リポジトリで提供しています:

```bash
git clone https://github.com/YujiSuzuki/ai-sandbox-demo
```

セットアップ手順は [ai-sandbox-demo](https://github.com/YujiSuzuki/ai-sandbox-demo) を参照してください。

→ 接続できない場合は [トラブルシューティング](docs/reference.ja.md#トラブルシューティング) を参照

## 次のステップ

- **セキュリティ機能を体験したい** → [ハンズオン](docs/hands-on.ja.md)
- **自分のプロジェクトで使いたい** → [自分のプロジェクトへの適用](docs/customization.ja.md)
- **設定漏れを検出したい** → `.sandbox/scripts/check-secret-sync.sh`（AI拒否設定とdocker-compose.ymlの同期チェック）

---

## テンプレートの更新

起動時に新バージョンを自動チェックします。更新があると、バージョン情報とリリースノートへのリンクが表示されます。

**一番簡単な方法:** AIアシスタントに頼む — `「最新バージョンに更新して」`。バージョン確認、競合検出、リビルドまで対応します。

**手動で更新:** [テンプレートの更新ガイド](docs/updating.ja.md)にclone・テンプレートそれぞれの手順を記載しています。

---


# コマンド

| コマンド | 実行場所 | 説明 |
|---------|---------|------|
| `hostmcp serve` | ホストOS | HostMCPサーバーを起動 |
| `hostmcp list` | ホストOS | アクセス可能なコンテナを一覧表示 |
| `hostmcp client list` | AI Sandbox | HTTP経由でコンテナ一覧 |
| `hostmcp client logs <container>` | AI Sandbox | HTTP経由でログ取得 |
| `hostmcp client exec <container> "cmd"` | AI Sandbox | HTTP経由でコマンド実行 |

> 詳細なコマンドオプションについては [HostMCP README](https://github.com/YujiSuzuki/hostmcp#cli-commands) を参照

# HostMCP ホストアクセス

HostMCP は他のコンテナだけでなく、**ホスト OS** へのアクセスも制御付きで AI に提供できます。3 つの機能があり、すべて `hostmcp.yaml` で設定可能です。

### ホストツール

`.sandbox/host-tools/` に配置されたスクリプトを AI が発見・実行できます。新しいツールは **承認ワークフロー** を経由します — `hostmcp tools sync` でレビュー後に初めて実行可能になります。

```
.sandbox/host-tools/         ← AI がツールを提案する場所（ステージング）
~/.hostmcp/host-tools/<id>/    ← 承認済みツールだけがここから実行される
```

`.sandbox/host-tools/` に自作スクリプトを置けば、AI が承認ワークフロー経由で実行できます。`demo-build.sh`・`demo-up.sh`・`demo-down.sh` を使ったサンプルは [ai-sandbox-demo](https://github.com/YujiSuzuki/ai-sandbox-demo) を参照してください。

### コンテナライフサイクル

Docker API を直接使って、コンテナの起動・停止・再起動を AI が行えます。デフォルトは無効（`lifecycle: false`）で、`allowed_containers` ポリシーに従います。

```yaml
# hostmcp.yaml 内
security:
  permissions:
    lifecycle: true  # 起動/停止/再起動を許可
```

### ホストコマンド

ホスト OS 上でホワイトリスト登録されたCLI コマンド（例: `git status`、`df -h`）を AI が実行できます。ベースコマンド＋引数パターンでマッチングし、拒否リストや危険モードにも対応しています。

```yaml
# hostmcp.yaml 内
host_access:
  host_commands:
    enabled: true
    whitelist:
      "git": ["status", "diff *", "log --oneline *"]
```

> 設定の詳細、承認ワークフロー、セキュリティ上の注意点は [HostMCP ホストアクセス](docs/host-access.ja.md) を参照

# AI SandBox 内部ツール

## 内部ツール とは

AI Sandbox の内部には **SandboxMCP** という軽量な MCP サーバー（stdio）が組み込まれています。コンテナ起動時に自動でビルド・登録され、`.sandbox/` 配下のスクリプトやツールを AI が検出・実行できるようにする仕組みです。

| 比較 | SandboxMCP | HostMCP |
|------|-----------|---------|
| 動作場所 | コンテナ内部（stdio） | ホスト OS（SSE / HTTP） |
| 目的 | スクリプト・ツールの検出と実行 | 他コンテナへのアクセス |
| 起動 | 自動（コンテナ起動時） | 手動（`hostmcp serve`） |

AI に「使えるスクリプトある？」「会話履歴を検索して」と聞くだけで、SandboxMCP 経由で適切なツールが実行されます。

> [!TIP]
> SandboxMCP の仕組みについては [docs/architecture.ja.md](docs/architecture.ja.md) を参照

## 付属ツール

すぐに使えるツールが２つ付属しています。

### 会話履歴の検索

Claude Code の過去の会話を検索できるツールが付属しています。AIに話しかけるだけで、過去の会話を横断的に検索して答えてくれます。

**こんな使い方ができます:**

| 聞き方 | AIがやってくれること |
|--------|---------------------|
| 「昨日の会話の概要わかる？」 | 昨日のメッセージを検索して要約 |
| 「先週なにやった？」 | 日ごとのセッションを調べて活動概要を作成 |
| 「HostMCP の設定どうしたっけ？」 | キーワードで過去の会話を検索 |
| 「あのバグ修正いつやった？」 | 日付やキーワードで該当会話を特定 |
| 「この謎のファイル、誰が作った？」 | 過去のAIセッションのコマンド履歴から原因を特定 |


> [!TIP]
> 詳しい使い方やオプションは [docs/search-history.ja.md](docs/search-history.ja.md) を参照

### トークン使用量レポート

Claude Code でどれくらいトークンを使っているか確認できるツールです。モデル別・期間別に集計して、API で使った場合のコスト見積もりもAIに聞けます。

**こんな使い方ができます:**

| 聞き方 | AIがやってくれること |
|--------|---------------------|
| 「今週どれくらい使った？」 | 直近7日間のトークン使用量をモデル別に集計 |
| 「先月の使用量とコスト教えて」 | 30日間の集計 + 公式サイトから価格を取得してコスト計算 |
| 「Pro プランと比べてどう？」 | API コストを算出し、Pro / Max プランと比較 |
| 「日別の内訳見せて」 | 日ごとのトークン消費量を表示 |

**コスト見積もりの仕組み:**

AIがその場で [公式の料金ページ](https://docs.anthropic.com/en/docs/about-claude/pricing) から最新価格を取得して計算するため、料金改定にも対応しやすい仕組みです。

```
ユーザー: 「先月の使用量とコスト教えて」
    ↓
AI: ① ツールでトークン数を集計
    ② 公式サイトから最新価格を取得
    ③ コスト計算 + Pro/Max プランとの比較表を出力
```

## 付属コマンド（Claude Code）

スラッシュコマンドとして使えるコードレビュー・リファクタ・テスト生成コマンドが付属しています。Git リポジトリがなくても動作します。

| コマンド | 用途 |
|---------|------|
| `/ais-local-review` | コードレビュー（バグ・CLAUDE.md準拠・回帰分析） |
| `/ais-local-security-review` | セキュリティレビュー |
| `/ais-local-performance-review` | パフォーマンスレビュー |
| `/ais-local-architecture-review` | アーキテクチャレビュー |
| `/ais-local-test-review` | テストの品質レビュー |
| `/ais-local-doc-review` | ドキュメントレビュー |
| `/ais-local-prompt-review` | AIコマンド／プロンプトファイルのレビュー |
| `/ais-refactor` | リファクタリング提案 |
| `/ais-test-gen` | テスト自動生成 |

**特徴:**
- Git リポジトリがなくても動作（ファイル指定でレビュー可能）
- 複数の専門エージェントが並列でレビューし、バッチスコアリング + 再検証の2段階で偽陽性を削減
- Confidence 75 以上の問題だけを報告するため、ノイズが少ない

**インストール:**

```bash
.sandbox/scripts/install-commands.sh --list   # 利用可能なコマンドを確認
.sandbox/scripts/install-commands.sh --all    # 全コマンドをインストール
```

インストール後、Claude Code を再起動すると `/ais-local-review` のように使えます。

> [!TIP]
> コマンドの作成経緯や自作コマンドの作り方は [プラグインガイド](docs/plugins.ja.md) を参照

## 自作ツール・スクリプトの追加

### 自作ツール

`.sandbox/tools/` に Go ファイルを置くだけで、AI が自動的に認識します。設定は不要です。

### 自作スクリプト

`.sandbox/scripts/` にシェルスクリプトを置いても同様に認識されます。
シェルスクリプトから Python や Node.js など他の言語を呼び出せるため、Go 以外の言語でもツールを作成できます。

> [!TIP]
> ファイル先頭のコメントに説明や使い方を書いておくと、AI がそれを読み取って活用します。
> ヘッダーコメントの書き方など詳細は [アーキテクチャ詳細](docs/architecture.ja.md#自作ツールの追加) を参照


# プロジェクト構造

`.sandbox/` に共有基盤、`.devcontainer/` と `cli_sandbox/` に2つのSandbox環境が配置されています。自分のプロジェクトはこれらの隣に追加してください。[HostMCP](https://github.com/YujiSuzuki/hostmcp) はホストOS上で別途動作します。

<details markdown="1">

<summary>ディレクトリツリーを見る</summary>

```
workspace/
├── .sandbox/               # 共有サンドボックス基盤
│   ├── Dockerfile          # コンテナイメージ定義
│   └── scripts/            # 共有スクリプト
│       ├── validate-secrets.sh    # 秘匿ファイルが隠蔽されているか確認
│       ├── check-secret-sync.sh   # AI拒否設定との同期チェック
│       └── sync-secrets.sh        # 対話的に設定を同期
│
├── .devcontainer/          # VS Code Dev Container 設定
│   ├── docker-compose.yml  # 秘匿情報隠蔽の設定
│   └── devcontainer.json   # VS Code統合設定（拡張機能、ポート制御等）
│
├── cli_sandbox/             # CLI サンドボックス（代替環境）
│   ├── claude.sh           # ターミナルから Claude Code を実行
│   ├── gemini.sh           # ターミナルから Gemini CLI を実行
│   ├── ai_sandbox.sh       # 汎用シェル（AI なしでデバッグ用）
│   └── docker-compose.yml
│
└── <your-project>/         # 自分のアプリケーションコード（ここに追加）
```

</details>

自分のプロジェクトの追加方法は [自分のプロジェクトへの適用](docs/customization.ja.md) を参照。


# セキュリティ機能

| 機能 | やっていること |
|------|--------------|
| **秘匿情報の隠蔽** | `.env` や `secrets/` をDockerマウントでAIから隠す。アプリ側は普通に読める |
| **コンテナアクセス制御** | HostMCPがセキュリティポリシーに基づき、AIのアクセス範囲を制限 |
| **Sandbox保護** | 非rootユーザー、制限されたsudo、ホストOSのファイルにアクセス不可 |
| **出力マスキング** | ログに含まれるパスワードやAPIキーをHostMCPが自動マスク |
| **起動時の自動検証** | 起動するたびに秘匿設定の整合性を自動チェック。問題があれば警告表示 |

→ 各機能の詳細・設定方法は [アーキテクチャ詳細](docs/architecture.ja.md)、起動時検証の詳細は [リファレンス](docs/reference.ja.md#起動時の自動検証) を参照



# 対応AIツール

- ✅ **Claude Code** (Anthropic) - 完全なMCPサポート
- ✅ **Gemini Code Assist** (Google) - Agentモードで MCP対応
- ✅ **Gemini CLI** (Google) - MCP対応
- ✅ **Cline** (VS Code拡張) - MCP統合（おそらく対応しています。未検証）



# よくある質問

**Q: Claude Code SandboxやDocker AI Sandboxesとの違いは？**
A: 補完関係にあります。Claude Code Sandboxは実行を制限し、Docker AI SandboxesはVM分離を提供します。本プロジェクトはファイルシステムレベルのシークレット隠蔽とコンテナ間アクセスを追加します。組み合わせて多層防御にできます。詳しくは [既存ソリューションとの比較](docs/comparison.ja.md) を参照してください。

**Q: HostMCPを使う必要がありますか？**
A: いいえ。HostMCPなしでも通常のサンドボックスとして機能します。HostMCPはクロスコンテナアクセスを可能にします。

**Q: Docker ソケットをコンテナに渡せば HostMCP は不要では？**
A: ソケットを渡すと AI がすべてのコンテナを自由に操作でき、秘匿情報の隠蔽も回避できてしまいます。HostMCP は「必要な操作だけ」を安全に提供するためのゲートウェイです。詳しくは [アーキテクチャ詳細](docs/architecture.ja.md#5-docker-ソケットを渡さない理由) を参照。

**Q: AI に `docker-compose up/down` を頼める？**
A: 直接は実行できませんが、承認済みホストツールを通じて同等の操作が可能です。`docker-compose` コマンドやイメージのビルドは人のみですが、ホストツールにより人がレビューしたスクリプト経由で制御されたアクセスを提供します。詳細は [HostMCP 設計思想](https://github.com/YujiSuzuki/hostmcp#design-philosophy) を参照してください。

**Q: 別の秘匿情報管理を使えますか？**
A: はい！HashiCorp VaultやAWS Secrets Manager等と組み合わせられます。本プロジェクトは開発時の保護を担い、本番環境では専用ツールをお使いください。



# ドキュメント

| ドキュメント | 内容 |
|-------------|------|
| [はじめてのセットアップガイド](docs/getting-started.ja.md) | ゼロから動く状態まで一歩ずつ案内 |
| [既存ソリューションとの比較](docs/comparison.ja.md) | Claude Code Sandbox、Docker AI Sandboxes等との比較 |
| [ハンズオン](docs/hands-on.ja.md) | セキュリティ機能を実際に体験する演習 |
| [自分のプロジェクトへの適用](docs/customization.ja.md) | テンプレートのカスタマイズ手順 |
| [リファレンス](docs/reference.ja.md) | 環境設定、オプション、トラブルシューティング |
| [アーキテクチャ詳細](docs/architecture.ja.md) | セキュリティの仕組みと構成図 |
| [ネットワーク制限](docs/network-firewall.ja.md) | ファイアウォールの導入方法 |
| [HostMCP ドキュメント](https://github.com/YujiSuzuki/hostmcp#readme) | MCPサーバーの詳細 |
| [HostMCP ホストアクセス](docs/host-access.ja.md) | ホストツール、コンテナライフサイクル、ホストコマンド実行 |
| [HostMCP 設計思想](https://github.com/YujiSuzuki/hostmcp#design-philosophy) | 段階的アクセスモデルとAI・人の役割分担 |
| [プラグインガイド](docs/plugins.ja.md) | マルチリポ構成でのClaude Codeプラグイン活用 |
| [デモアプリガイド](https://github.com/YujiSuzuki/ai-sandbox-demo) | SecureNoteデモの実行方法（別リポジトリ） |
| [CLI Sandbox ガイド](cli_sandbox/README.ja.md) | ターミナルベースのサンドボックス |

> **Note:** `docs/ai-guide.md` は AI アシスタント向けの参照ガイドです（CLAUDE.md・GEMINI.md から参照）。ユーザーが読む必要はありません。

## ライセンス

MIT License - [LICENSE](LICENSE) を参照
