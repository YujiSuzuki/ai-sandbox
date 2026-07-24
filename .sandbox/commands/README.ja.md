# AI-Sandbox 付属のカスタムコマンド

[English version here](README.md)

[← プラグインガイド に戻る](../../docs/plugins.ja.md)

[← README.ja.md に戻る](../../README.ja.md)


`.sandbox/commands/` には、Claude Code の `/code-review` プラグインを土台に、以下の改良を加えたカスタムコマンドが用意されています：
- Git リポジトリがなくても動作（Non-Git モード対応）
- 専門レビュー5種類（general / security / performance / architecture / prompt）
- バッチスコアリング + Validation の2段階検証で偽陽性を削減

## インストール方法

Claude Code に「カスタムコマンドをインストールして」と頼むか、`install-commands.sh` を直接使用します：

```bash
.sandbox/scripts/install-commands.sh --list             # 利用可能なコマンドを確認
.sandbox/scripts/install-commands.sh ais-local-review    # ais-local-review をインストール
.sandbox/scripts/install-commands.sh --all               # 全コマンドをインストール
```

## 付属コマンド一覧

| コマンド | 説明 |
|---------|------|
| `/ais-local-review` | コードレビュー（general / security / performance / architecture / prompt の5種類）<br>コミット前の総合チェックや、観点を絞った専門レビューに。 |
| `/ais-local-architecture-review` | アーキテクチャレビュー<br>設計パターン・責務の分離・依存関係・コード構成が適切かチェックしたいとき。 |
| `/ais-local-security-review` | セキュリティレビュー<br>認証・認可・インジェクションリスク・シークレット漏洩などの脆弱性を洗い出したいとき。 |
| `/ais-local-performance-review` | パフォーマンスレビュー<br>計算効率・メモリ使用・I/O パターン・スケーラビリティの問題を発見したいとき。 |
| `/ais-local-test-review` | テスト品質レビュー<br>テストが実際の挙動を検証しているか、カバレッジの抜けや anti-pattern がないか確認したいとき。 |
| `/ais-local-doc-review` | ドキュメントの正確性・一貫性・わかりやすさをレビュー<br>README や仕様書の記述がコードと食い違っていないか、読みやすいか確認したいとき。 |
| `/ais-local-comment-review` | コードコメントの客観的妥当性・初見でのわかりやすさ・過不足・存在意義をレビュー<br>差分ではなくファイル全体を走査するため、diff ベースのレビューでは拾えない古い/無意味なコメントも検出したいとき。 |
| `/ais-local-spec-review` | 設計書（仕様書）の品質レビュー（網羅性・整合性・テスト項目の妥当性など）<br>実装開始前に仕様書自体の抜け漏れ・矛盾・実装者が迷う箇所を潰したいとき。 |
| `/ais-local-prompt-review` | AI コマンド／プロンプトファイルのレビュー<br>`.claude/commands/` 等のプロンプト品質・コマンド間の一貫性を確認したいとき。 |
| `/ais-local-design-enhance` | 設計書のブレインストーミング・強化（不足要素の特定と追記案の生成）<br>設計書を書いている途中で見落としを洗い出し、そのまま貼れる追記文を生成したいとき。 |
| `/ais-refactor` | リファクタリング改善の具体的な提案<br>動いているコードをより読みやすく・保守しやすくするための具体的な変換を提案してほしいとき。 |
| `/ais-test-gen` | 変更コードに対するテストの自動生成<br>実装したコードのテストをゼロから書きたいとき。エッジケース・エラーハンドリングもカバー。 |

いずれも Git リポジトリがなくても動作します。
