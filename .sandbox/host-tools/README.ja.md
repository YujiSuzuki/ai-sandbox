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

**`@timeout` だけでは足りない場合があります。** これはホスト OS 上でスクリプトを強制終了するまでの時間を延ばすだけです。MCP の `run_host_tool` 経由の呼び出しは別レイヤーの待機時間を持ち（デフォルト60秒、`MCP_TOOL_TIMEOUT` 未設定時）、ホスト側のスクリプトが60秒を超えて動き続けていても、呼び出し側には失敗したように見えることがあります。スクリプトの `@timeout` がこのMCP側の既定値を超える場合は、`run_host_tool` に `client_timeout_seconds` を渡すか、Bash経由で `hostmcp client --timeout <秒数> ...`（スクリプト自身の `@timeout` に合わせる）にフォールバックしてください。両レイヤーを揃えた具体例は `xcode-test.sh` のヘッダーを参照してください。

詳細: [docs/host-access.md](../../docs/host-access.md)

---

## スクリプト一覧

| ファイル | 用途 | 動作環境 |
|---------|------|---------|
| `xcode-build.sh` | Xcode ビルド（構文チェック用） | macOS のみ |
| `xcode-test.sh` | Xcode テスト実行 | macOS のみ |
| `xcode-archive.sh` | Xcode アーカイブ（TestFlight / App Store 提出用） | macOS のみ |
| `xcode-install-app.sh` | ビルドして .app を固定ディレクトリ（デフォルト: `~/.hostmcp/Applications`）にコピー | macOS のみ |
| `mac-memory.sh` | macOS メモリ使用状況確認 | macOS のみ |
| `run-host-setup-tests.sh` | `.sandbox/host-setup/test-*.sh` を全件(または `--test-script` で1件)実行 | クロスプラットフォーム |
| `docker-compose-up.sh` | 任意の docker-compose ファイルからコンテナを起動 | クロスプラットフォーム |
| `docker-compose-down.sh` | 任意の docker-compose ファイルからコンテナを停止 | クロスプラットフォーム |
| `docker-compose-build.sh` | 任意の docker-compose ファイルからイメージをビルド | クロスプラットフォーム |
| `docker-compose-config.sh` | 1つ以上の docker-compose ファイルをマージした結果を検証・表示（読み取り専用） | クロスプラットフォーム |
| `xcodegen-generate.sh` | XcodeGen の `project.yml` から `.xcodeproj` を生成 | macOS のみ |
| `check-gvisor.sh` | gVisor(runsc)をDockerランタイムとして使える状態か確認（読み取り専用） | クロスプラットフォーム |
| `check-xcode.sh` | Xcodeがインストールされ使用可能な状態か確認（読み取り専用） | クロスプラットフォーム（macOS固有のチェックあり） |
| `xcode-simulator-screenshot.sh` | iOSアプリをビルドしシミュレータにインストール・起動してスクリーンショットを撮影（`--ui-test`で起動画面より先の特定画面も可） | macOSのみ |
| `restart-simulator.sh` | 全シミュレータデバイスのシャットダウン、および/またはSimulator.appの完全終了・再起動 | macOSのみ |
| `simulator-app-reset.sh` | シミュレータ全体を再起動せずに、特定の1アプリだけをアンインストール、および/または通知など個別のプライバシー許可をリセット | macOSのみ |

---

## xcode-build.sh / xcode-test.sh / xcode-archive.sh

> **macOS 専用。** Xcode がインストールされたホスト OS でのみ動作します。

`.xcodeproj` を自動検出して実行します。

```bash
# 自動検出（WORKSPACE_DIR の 2 階層以内を検索）
./xcode-build.sh

# プロジェクトを明示指定（絶対パス）
./xcode-build.sh --project /path/to/MyApp.xcodeproj

# プロジェクトを明示指定（WORKSPACE_DIR からの相対パスでも可 -- 自動検出が
# 届かないより深い場所にプロジェクトがある場合、これが一番簡単な指定方法)
./xcode-build.sh --project myapp/ios/MyApp.xcodeproj

# スキームを指定（デフォルト: .xcodeproj のベース名）
./xcode-build.sh --scheme MyAppDebug
```

> 自動検出は `WORKSPACE_DIR` 配下**2階層まで**しか探索しません(`find -maxdepth 2`)。
> `WORKSPACE_DIR/myapp/ios/MyApp.xcodeproj` のように、サブリポジトリ内の`ios/`配下など
> それより深い場所(myapp→ios→MyApp.xcodeprojの3階層)にある場合、「ワークスペース配下」
> ではあっても自動検出されないため、`--project`を明示的に指定する必要があります。

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

**特定のテストメソッドを1つだけ実行したい場合(XCTestのクラス名とターゲット名が同じ場合)**:
`--only`の2段形式「Class/Method」は、`xcodebuild -only-testing:`が最初のセグメントを
常に*ターゲット*名として解釈することを前提にした挙動です。上のスクリプトの例が動くのは
ターゲット名(`MyAppTests`)とクラス名(`MyFeatureTests`)が異なるため、xcodebuildが
最初のセグメントをクラス名として解釈し直してくれるからです。しかしUIテストのクラスは
慣習的にターゲットと同じ名前が付けられる(例: ターゲット`MyAppUITests`の中のクラス
`MyAppUITests`)ため、その場合は2段形式が`Target/Class`と解釈されてしまい、テストが
黙って0件になります。3段すべてを指定してください。

```bash
# ❌ 0件 -- Target=MyAppUITests / Class=testSomething と解釈される(該当クラスなし)
./xcode-test.sh --no-skip-ui-tests --test-target MyAppUITests --only "MyAppUITests/testSomething"

# ✅ Target/Class/Method
./xcode-test.sh --no-skip-ui-tests --test-target MyAppUITests --only "MyAppUITests/MyAppUITests/testSomething"

# ✅ さらに、自動検出の2階層より深い場所にあるプロジェクトの場合(上記参照)
./xcode-test.sh --project myapp/ios/MyApp.xcodeproj --no-skip-ui-tests \
  --test-target MyAppUITests --only "MyAppUITests/MyAppUITests/testSomething"
```

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
./docker-compose-down.sh ./docker-compose.yml -- --remove-orphans
./docker-compose-build.sh ./docker-compose.yml -- --no-cache
```

`docker-compose-down.sh` は破壊的なフラグ（`-v`/`--volumes`, `--rmi`）を拒否します — コンテナの停止/削除のみを行い、ボリュームやイメージは削除しません。

HostMCP の `run_host_tool` 経由で実行されるため、Docker ソケットへのアクセスがない
AI Sandbox 内からでも、ユーザーに `docker compose` の手動実行を頼まずにコンテナの
起動・停止・ビルドができます。プロジェクト固有の要件（compose ファイルパスの固定化、
追加の環境変数、ログメッセージ中のサービス名など）がある場合は、このスクリプトを
コピーして調整してください。

---

## docker-compose-config.sh

読み取り専用の診断スクリプト: `docker compose config` で1つ以上の docker-compose
ファイルをマージした結果を表示・検証します。イメージのビルドやコンテナの起動など、
変更は一切行いません。ベースの `docker-compose.yml` にマージして使うオーバーライド
ファイルなどのYAML構文検証に使えます。ユーザーに `docker compose` の手動実行を
頼む必要がありません。

```bash
# 単一ファイルを検証
./docker-compose-config.sh /path/to/docker-compose.yml

# ベースファイルにオーバーライドをマージして検証（順序は -f -f と同じ）
./docker-compose-config.sh ./docker-compose.yml ./docker-compose.override.yml

# -- の後に docker compose の追加オプションを渡せる
./docker-compose-config.sh ./docker-compose.yml -- --services
```

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

---

## check-xcode.sh

ホスト OS 上で Xcode がインストールされ使用可能な状態かどうかを確認する、
読み取り専用の診断スクリプトです。設定変更は一切行いません。`xcode-build.sh` /
`xcode-test.sh` / `xcode-archive.sh` / `xcode-install-app.sh` / `xcodegen-generate.sh`
を実行する前に、これらがこのホストで動作するかどうかをビルド失敗で気づく前に
事前確認できます。

```bash
./check-xcode.sh
```

確認内容:
- ホスト OS が macOS かどうか（上記スクリプト群は macOS 専用のため）
- アクティブな開発者ディレクトリが Command Line Tools か フル Xcode か（`xcode-select -p`）
- `xcodebuild` が動作するか（ライセンス未同意エラーを含む）
- インストール済みの iOS Simulator ランタイム（`xcrun simctl` で確認）

---

## xcode-simulator-screenshot.sh

> **macOS専用。** ホストOSに Xcode と iOS Simulator ランタイムが1つ以上インストールされている必要があります。

iOSアプリをビルドし、シミュレータにインストール・起動した上で、`WORKSPACE_DIR` 配下の
パスにスクリーンショットを保存します。共有ワークスペースのマウントだけが、ホストの画面を
AIに見せられる唯一の経路です。

```bash
# .xcodeproj を自動検出し、tmp/simulator-screenshot.png に保存
./xcode-simulator-screenshot.sh

# スキームと保存先（WORKSPACE_DIR からの相対パス）を指定
./xcode-simulator-screenshot.sh --scheme MyApp --output tmp/home.png

# 起動後、撮影までの待機秒数を延ばす（デフォルト: 3秒）
./xcode-simulator-screenshot.sh --wait 5

# 起動画面より先の画面を、自分で遷移してスクリーンショットを撮るUIテスト経由で撮影
# （そのテストの書き方は docs/ai-guide.md の「XCUITest Screenshot Automation」節を参照）
./xcode-simulator-screenshot.sh --scheme MyApp --ui-test "MyAppUITests/MyAppUITests/testSettingsScreenshot" --output tmp/settings.png
```

`--output` は `WORKSPACE_DIR` からの相対パスで指定する必要があります（`..` や絶対パスは不可）。
ビルドログの保存先:

```
<workspace>/tmp/xcode-simulator-screenshot-build.log
```

`--ui-test <Target>/<Class>/<method>` は、指定した1つのXCUITestメソッドを`xcodebuild test`
経由で実行し、そのテストが`XCTAttachment`で撮ったスクリーンショットを`xcresulttool`で取り出します
（デフォルトのsimctl install/launch/screenshotフローの代わりに）。起動画面より先の画面を
撮影できるのはこの経路です。`--wait`はこのモードでは無視されます（テスト自身の
`waitForExistence`がタイミングを制御するため）。このモードのbuild+testはプレーンな
ビルドより余裕を持たせる必要があるため、このスクリプトは`@timeout: 600`を宣言しています——
このスクリプトへの変更を取り込んだ後は、ホスト上で`hostmcp tools sync`を再実行して承認し、
呼び出し時は`--timeout 600`（CLI）または`client_timeout_seconds: 600`（`run_host_tool`）を
渡してください。

---

## restart-simulator.sh

> **macOS専用。** ホストOSに Xcode / Command Line Tools（`xcrun`）が必要です。

起動中の全シミュレータデバイスをシャットダウン（`xcrun simctl shutdown all`）し、デフォルトでは
Simulator.appも完全終了します（再起動はしません）。シミュレータがフリーズした、アプリの状態が
壊れた、デバイスが起動しなくなったなど、Xcodeからの通常の再起動では直らない場合に使います。

> **影響範囲はプロジェクト単位ではなくホスト全体です。** Simulator.appとCoreSimulator
> デーモンはMac全体で共有されています。実行すると、他プロジェクトでの作業や手動テスト、
> アタッチ中のデバッガなど、このプロジェクト以外で開いているシミュレータセッションも
> 巻き込んで中断されます。

> **再起動はあえてオプトイン（`--reopen`指定時のみ）にしています。** `xcode-test.sh`
> （`xcodebuild test`）と`xcode-simulator-screenshot.sh`（`xcrun simctl bootstatus -b` +
> `simctl install`/`launch`）はどちらもSimulator.appのGUIが開いているかに関わらず
> ヘッドレスに対象デバイスを起動するため、このスクリプトの直後にビルド/テストを走らせる
> だけなら再起動は不要です。自分の目でシミュレータを確認したい時だけ`--reopen`を付けて
> ください。

```bash
# 全デバイスをシャットダウンし、Simulator.appを終了（そのまま閉じたまま）
./restart-simulator.sh

# デバイスのシャットダウンのみ（Simulator.appはそのまま起動継続）
./restart-simulator.sh --shutdown-only

# デバイスをシャットダウンし、Simulator.appを終了してから再起動する（手動確認用）
./restart-simulator.sh --reopen

# フリーズしたSimulator.appを強制終了する
./restart-simulator.sh --force
```

---

## simulator-app-reset.sh

> **macOS専用。** ホストOSに Xcode / Command Line Tools（`xcrun`）が必要です。

シミュレータ全体を再起動せずに、特定の1アプリだけをアンインストール、および/または
通知・カメラ・写真などのプライバシー許可を個別にリセットします。

> **存在理由。** iOS/iPadOSは通知許可ダイアログの「許可」/「許可しない」といった決定を、
> アプリのコンテナ内ではなくデバイス側のプライバシーデータベースにbundle ID単位で記憶します。
> `xcode-build.sh`・`xcode-test.sh`・`xcode-simulator-screenshot.sh`による通常の
> ビルド→インストールでは、この決定は**クリアされません**。フレッシュユーザーが実際に見る
> ダイアログを確認したい場合や、以前の実行で「許可しない」のまま止まってしまったUIテストを
> 復旧したい場合、これをクリーンな状態に戻す手段が他にありませんでした。

```bash
# アプリを完全にアンインストール(このアプリの全プライバシー許可もクリアされる)
./simulator-app-reset.sh --bundle-id com.example.MyApp --uninstall

# アプリは残したまま、通知許可ダイアログだけ再度出るようにする
./simulator-app-reset.sh --bundle-id com.example.MyApp --reset-privacy notifications

# 両方を、デバイスを明示して実行
./simulator-app-reset.sh --bundle-id com.example.MyApp --device <udid> --uninstall --reset-privacy all
```
