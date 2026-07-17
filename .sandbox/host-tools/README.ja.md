# host-tools

[English README is here](README.md)

このディレクトリのスクリプトは、HostMCP の `run_host_tool` 経由でホスト OS 上で実行されます。

## ⚠️ スクリプトを追加・変更したら必ず実行

```bash
hostmcp tools sync
```

**ホスト OS 上で**上記コマンドを実行しないと、変更が HostMCP に反映されません。

### なぜ必要か

このディレクトリはコンテナ内（ステージング）です。
実際に実行されるのは `~/.hostmcp/host-tools/<project-id>/` にある承認済みコピーです。

```
1. .sandbox/host-tools/ にスクリプトを置く   ← AI・開発者が編集できる
2. hostmcp tools sync を実行                  ← ホスト OS で差分を確認・承認
3. ~/.hostmcp/host-tools/<project-id>/ にコピー ← ここが実際に実行される
```

SHA256 ハッシュで変更を検知するため、**編集のたびに再承認が必要**です。

詳細: [docs/host-access.md](../../docs/host-access.md)

---

## スクリプト一覧

| ファイル | 用途 | 動作環境 |
|---------|------|---------|
| `xcode-build.sh` | Xcode ビルド（構文チェック用） | macOS のみ |
| `xcode-test.sh` | Xcode テスト実行 | macOS のみ |
| `xcode-archive.sh` | Xcode アーカイブ（TestFlight / App Store 提出用） | macOS のみ |
| `copy-credentials.sh` | 認証情報のコピー | クロスプラットフォーム |
| `mac-memory.sh` | macOS メモリ使用状況確認 | macOS のみ |
| `run-host-setup-tests.sh` | `.sandbox/host-setup/test-*.sh` を全件(または `--test-script` で1件)実行 | クロスプラットフォーム |
| `docker-compose-up.sh` | 任意の docker-compose ファイルからコンテナを起動 | クロスプラットフォーム |
| `docker-compose-down.sh` | 任意の docker-compose ファイルからコンテナを停止 | クロスプラットフォーム |
| `docker-compose-build.sh` | 任意の docker-compose ファイルからイメージをビルド | クロスプラットフォーム |

---

## xcode-build.sh / xcode-test.sh / xcode-archive.sh

> **macOS 専用。** Xcode がインストールされたホスト OS でのみ動作します。

`.xcodeproj` を自動検出して実行します。

```bash
# 自動検出（WORKSPACE_DIR の 2 階層以内を検索）
./xcode-build.sh

# プロジェクトを明示指定
./xcode-build.sh --project /path/to/MyApp.xcodeproj

# スキームを指定（デフォルト: .xcodeproj のベース名）
./xcode-build.sh --scheme MyAppDebug
```

### xcode-test.sh の `--only` オプション

`--only` に指定するのは **ファイル名ではなく Swift の `struct` 名**です。

```bash
# ✅ struct 名で指定
./xcode-test.sh --only MyFeatureTests

# ❌ ファイル名で指定 → 0 テストになる
./xcode-test.sh --only MyFeature   # ファイル名
```

テストターゲットを指定する場合は `--test-target` を使います。

```bash
# デフォルト: <Scheme>Tests/MyFeatureTests
./xcode-test.sh --only MyFeatureTests

# 別ターゲットを指定
./xcode-test.sh --test-target MyAppIntegrationTests --only MyFeatureTests
```

UI テストは `--no-skip-ui-tests` を付けると実行されます（デフォルトはスキップ）。

### ビルドエラーの確認

`xcode-build.sh` 実行後にエラーがあると、サマリーが保存されます：

```
<workspace>/tmp/xcode-build-errors.txt
```

コンテナ内から Read ツールで直接読めます。

---

## run-host-setup-tests.sh

`.sandbox/host-setup/test-*.sh` をホスト OS 上で実行します。デフォルトは全件、
`--test-script <name>` で1件のみに絞れます。これらのテストスイートは実ネットワーク・
実 `go`/`curl`・実シェル設定ファイルを必要とするため、AI Sandbox コンテナ内では
実行を拒否する仕組みになっており、このホストツールが必要です。

```bash
./run-host-setup-tests.sh
./run-host-setup-tests.sh --test-script test-install-hostmcp.sh
```

各スイートの全出力は以下にも保存されます：

```
<workspace>/.sandbox/tmp/<テストスクリプト名>-output.log
```

コンテナ内から Read ツールで直接読めます。

---

## copy-credentials.sh

認証情報をコピーします。クロスプラットフォームで動作します。

---

## mac-memory.sh

> **macOS 専用。** macOS のメモリ使用状況を表示します。

---

## docker-compose-up.sh / docker-compose-down.sh / docker-compose-build.sh

`docker compose up -d` / `down` / `build` をホスト OS 上で実行する汎用ラッパーです。
これはサンプルスクリプトであり、あらゆるプロジェクトに対応する完成品ではなく、出発点として用意しています。
`ai-sandbox-demo/.sandbox/host-tools/` にある `demo-up.sh` / `demo-down.sh` / `demo-build.sh`
（compose ファイルのパスが固定されているデモ専用版）を汎用化したものです。

```bash
# コンテナ起動
./docker-compose-up.sh /path/to/docker-compose.yml

# コンテナ停止
./docker-compose-down.sh /path/to/docker-compose.yml

# イメージビルド
./docker-compose-build.sh /path/to/docker-compose.yml

# -- の後に docker compose の追加オプションを渡せる
./docker-compose-up.sh ./docker-compose.yml -- --build
./docker-compose-down.sh ./docker-compose.yml -- --volumes
./docker-compose-build.sh ./docker-compose.yml -- --no-cache
```

HostMCP の `run_host_tool` 経由で実行されるため、Docker ソケットへのアクセスがない
AI Sandbox 内からでも、ユーザーに `docker compose` の手動実行を頼まずにコンテナの
起動・停止・ビルドができます。プロジェクト固有の要件（compose ファイルパスの固定化、
追加の環境変数、ログメッセージ中のサービス名など）がある場合は、このスクリプトを
コピーして調整してください。
