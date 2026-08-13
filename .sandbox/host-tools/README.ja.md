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

スクリプトが独自のタイムアウトを宣言している場合（ヘッダーの `# @timeout: <秒数>` 行。例: `xcode-test.sh`）、`hostmcp tools sync` は承認を求める前に必ずその宣言を表示します。`y` と入力する前にそこで確認してください。

詳細: [docs/host-access.md](../../docs/host-access.md)

---

## スクリプト一覧

| ファイル | 用途 | 動作環境 |
|---------|------|---------|
| `xcode-build.sh` | Xcode ビルド（構文チェック用） | macOS のみ |
| `xcode-test.sh` | Xcode テスト実行 | macOS のみ |
| `xcode-archive.sh` | Xcode アーカイブ（TestFlight / App Store 提出用） | macOS のみ |
| `xcode-install-app.sh` | ビルドして .app を固定ディレクトリ（デフォルト: `~/.hostmcp/Applications`）にコピー | macOS のみ |
| `copy-credentials.sh` | 認証情報のコピー | クロスプラットフォーム |
| `mac-memory.sh` | macOS メモリ使用状況確認 | macOS のみ |
| `run-host-setup-tests.sh` | `.sandbox/host-setup/test-*.sh` を全件(または `--test-script` で1件)実行 | クロスプラットフォーム |
| `docker-compose-up.sh` | 任意の docker-compose ファイルからコンテナを起動 | クロスプラットフォーム |
| `docker-compose-down.sh` | 任意の docker-compose ファイルからコンテナを停止 | クロスプラットフォーム |
| `docker-compose-build.sh` | 任意の docker-compose ファイルからイメージをビルド | クロスプラットフォーム |
| `xcodegen-generate.sh` | XcodeGen の `project.yml` から `.xcodeproj` を生成 | macOS のみ |
| `check-gvisor.sh` | gVisor(runsc)をDockerランタイムとして使える状態か確認（読み取り専用） | クロスプラットフォーム |

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

推奨: ファイル名と同名の外枠 struct を作り、内部の struct を入れ子にする方法です。struct 名がファイル名と一致するため `--only` が期待通りに動作しつつ、関連するテストをグループ化できます。

```swift
// FeatureTests.swift
struct FeatureTests {
    struct Loading { /* @Test 関数 */ }
    struct Saving { /* @Test 関数 */ }
}
```

UI テストは `--no-skip-ui-tests` を付けると実行されます（デフォルトはスキップ）。

### ビルドエラーの確認

`xcode-build.sh` 実行後にエラーがあると、サマリーが保存されます：

```
<workspace>/tmp/xcode-build-errors.txt
```

コンテナ内から Read ツールで直接読めます。

---

## xcode-install-app.sh

> **macOS 専用。** Xcode がインストールされたホスト OS でのみ動作します。

アプリをビルドし、DerivedData 配下の（予測できないハッシュ付きの）パスから
固定ディレクトリ ─ デフォルトでは `~/.hostmcp/Applications` ─ へ `.app` をコピーします。DerivedData の
ハッシュ付きパスを探し当てる代わりに、コンテナ側から常に同じ既知のパスを参照できる
ようにするためのツールです。

> **上書きの仕組み**: `--dest-dir` は `$HOME` 配下のパスにのみ解決できるようスクリプト側で
> 強制されており（範囲外は拒否）。その配下のうち、ビルド成果物名（例: `MyApp.app`）と同名の
> サブフォルダだけが `rsync --delete` で新しいビルドと完全に同期されます（コピー元にない
> ファイルは削除する）。そのため同じアプリを再インストールする分には新旧が混在せず常に
> クリーンな状態になりますが、同じ `--dest-dir` を共有する他のアプリには影響しません。
> なお、同一プロジェクトでもビルド成果物名が変わった場合、旧名のフォルダは削除されずに
> 残ります。

```bash
# ビルドして ~/.hostmcp/Applications にインストール
./xcode-install-app.sh --project /path/to/MyApp.xcodeproj

# インストール先を変更
./xcode-install-app.sh --scheme MyApp --dest-dir ~/.local/App
```

変わるのは「コピー後の設置場所」だけで、Xcode 自体のビルド先（DerivedData）には
手を加えません。後で Xcode を直接開いて同じプロジェクトをビルドしても、通常どおり
動作します。

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

`docker-compose.yml` を元に、DevContainerプロジェクト間でホームディレクトリ（認証情報・設定・履歴）をエクスポート/インポートします。クロスプラットフォームで動作します。

```bash
# 現在のワークスペースのホームディレクトリをバックアップ先にエクスポート
./copy-credentials.sh --export /path/to/workspace ~/backup

# 別のワークスペースにインポート
./copy-credentials.sh --import ~/backup /path/to/other-workspace
```

---

## mac-memory.sh

> **macOS 専用。** macOS のメモリ使用状況を表示します。

---

## docker-compose-up.sh / docker-compose-down.sh / docker-compose-build.sh

`docker compose up -d` / `down` / `build` をホスト OS 上で実行する汎用ラッパーです。
これはサンプルスクリプトであり、あらゆるプロジェクトに対応する完成品ではなく、出発点として用意しています。

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

---

## xcodegen-generate.sh

> **macOS 専用。** ホスト側に [XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です: `brew install xcodegen`

XcodeGen の `project.yml` から `.xcodeproj` を生成します。

```bash
# spec ファイルと同じディレクトリに生成
./xcodegen-generate.sh /path/to/project.yml

# -- の後に xcodegen の追加オプションを渡せる
./xcodegen-generate.sh ./project.yml -- --use-cache
```

`.xcodeproj` は spec ファイルと同じディレクトリに生成されます。

---

## check-gvisor.sh

ホスト OS 上で gVisor（`runsc`）が Docker ランタイムとして使える状態かどうかを確認する、
読み取り専用の診断スクリプトです。設定変更は一切行いません。

```bash
./check-gvisor.sh
```

確認内容:
- Docker デーモンに到達できるか
- `runsc` が Docker のランタイムとして既に登録されているか（`docker info` の `Runtimes`）
- ホスト OS の PATH 上に `runsc` バイナリが見つかるか
- OS（Linux / macOS）に応じた次のステップの案内

macOS では Docker Desktop / OrbStack がコンテナを独自の Linux VM 内で実行しており、
この VM 境界によって既に一段階の隔離が働いているため、gVisor の追加導入は基本的に
不要です（詳細は [docs/comparison.ja.md](../../docs/comparison.ja.md#隔離技術としての位置づけ)
を参照）。
