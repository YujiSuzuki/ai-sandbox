# host-tools

このディレクトリのスクリプトは、DockMCP の `run_host_tool` 経由でホスト OS（macOS）上で実行されます。

## ⚠️ スクリプトを追加・変更したら必ず実行

```bash
dkmcp tools sync
```

**ホスト OS 上で**上記コマンドを実行しないと、変更が DockMCP に反映されません。

### なぜ必要か

このディレクトリはコンテナ内（ステージング）です。
実際に実行されるのは `~/.dkmcp/host-tools/<project-id>/` にある承認済みコピーです。

```
1. .sandbox/host-tools/ にスクリプトを置く   ← AI・開発者が編集できる
2. dkmcp tools sync を実行                  ← ホスト OS で差分を確認・承認
3. ~/.dkmcp/host-tools/<project-id>/ にコピー ← ここが実際に実行される
```

SHA256 ハッシュで変更を検知するため、**編集のたびに再承認が必要**です。

詳細: [docs/host-access.md](../../docs/host-access.md)

## スクリプト一覧

| ファイル | 用途 |
|---------|------|
| `xcode-build.sh` | Xcode ビルド（構文チェック用） |
| `xcode-test.sh` | Xcode テスト実行（xcresulttool で結果表示） |
| `xcode-archive.sh` | Xcode アーカイブ（TestFlight / App Store 提出用） |
| `copy-credentials.sh` | 認証情報のコピー |
| `mac-memory.sh` | macOS メモリ使用状況確認 |

## xcode スクリプト共通オプション

3 つの xcode スクリプトはいずれも `.xcodeproj` を自動検出します。

```bash
# 自動検出（WORKSPACE_DIR 2階層以内を検索）
./xcode-build.sh

# 明示指定
./xcode-build.sh --project /path/to/MyApp.xcodeproj

# スキームを指定（デフォルト: .xcodeproj のベース名）
./xcode-build.sh --scheme MyAppDebug
```

## xcode-test.sh の `--only` オプションについて

`--only` に指定するのは **ファイル名ではなく Swift の `struct` 名**（`@Suite` に対応する型名）。

```bash
# ❌ ファイル名で指定 → 0 テストになる
./xcode-test.sh --only FeatureTests   # ファイル名

# ✅ struct 名で指定
./xcode-test.sh --only HandleFeatureTests   # ファイル内の struct 名
```

ファイル内に複数の `@Suite struct` がある場合、それぞれを個別に指定する必要があります。
ファイル名と同名の外枠 `struct` を持つファイルは `--only ファイル名` でまとめて実行できます。

```swift
// 推奨パターン: 外枠 struct をファイル名と一致させる
@Suite struct FeatureTests {             // ← --only FeatureTests で一括実行可
    @Suite struct HandleFeatureTests { ... }
    @Suite struct PerformFeatureTests  { ... }
}
```

### テストターゲットの指定

`--only` でターゲット名が省略された場合、`<Scheme>Tests` が自動補完されます。
別のターゲット名の場合は `--test-target` で指定してください。

```bash
# デフォルト: MyAppTests/HandleFeatureTests
./xcode-test.sh --only HandleFeatureTests

# 別ターゲット: MyAppIntegrationTests/HandleFeatureTests
./xcode-test.sh --test-target MyAppIntegrationTests --only HandleFeatureTests

# TargetName/ClassName 形式でも可（自動補完されない）
./xcode-test.sh --only "MyAppTests/HandleFeatureTests"
```

### UI テストの実行

デフォルトでは `<Scheme>UITests` ターゲットはスキップされます。

```bash
# UI テストもあわせて実行
./xcode-test.sh --no-skip-ui-tests
```

## ビルドエラーの確認方法

`xcode-build.sh` 実行後にエラーが出た場合、サマリーが以下に保存されます：

```
<workspace>/tmp/xcode-build-errors.txt
```

コンテナ内から `Read` ツールで直接読めます。
