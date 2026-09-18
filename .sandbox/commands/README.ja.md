# AI-Sandbox 付属のカスタムコマンド

[English version here](README.md)

[← プラグインガイド に戻る](../../docs/plugins.ja.md)

[← README.ja.md に戻る](../../README.ja.md)


`.sandbox/commands/` には、Claude Code の `/code-review` プラグインを土台に、以下の改良を加えたカスタムコマンドが用意されています：
- Git リポジトリがなくても動作（Non-Git モード対応）
- 専門レビュー5種類（general / security / performance / architecture / prompt）
- バッチスコアリング + Validation の2段階検証で偽陽性を削減

## インストール方法

Claude Code に「カスタムコマンドをインストールして」と頼むか、`install-commands.py` を直接使用します：

```bash
.sandbox/scripts/install-commands.py --list             # 利用可能なコマンドを確認
.sandbox/scripts/install-commands.py ais-local-review    # ais-local-review をインストール
.sandbox/scripts/install-commands.py --all               # 全コマンドをインストール
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
| `/ais-local-design-challenge` | 複数の立場（懐疑的レビュアー、ユーザー代弁者、運用担当者、代替案アーキテクト）から設計を検証<br>spec-reviewの前に、編集案を出さずに反論・懸念・代替案だけを洗い出す。「このアプローチで良いか」の判断を、今の文言に引っ張られず人間に残したいとき。 |
| `/ais-local-spec-review` | 設計書（仕様書）の品質レビュー（網羅性・整合性・テスト項目の妥当性など）<br>実装開始前に仕様書自体の抜け漏れ・矛盾・実装者が迷う箇所を潰したいとき。 |
| `/ais-local-prompt-review` | AI コマンド／プロンプトファイルのレビュー<br>`.claude/commands/` 等のプロンプト品質・コマンド間の一貫性を確認したいとき。 |
| `/ais-local-design-enhance` | 設計書のブレインストーミング・強化（不足要素の特定と追記案の生成）<br>設計書を書いている途中で見落としを洗い出し、そのまま貼れる追記文を生成したいとき。 |
| `/ais-refactor` | リファクタリング改善の具体的な提案<br>動いているコードをより読みやすく・保守しやすくするための具体的な変換を提案してほしいとき。 |
| `/ais-test-gen` | 変更コードに対するテストの自動生成<br>実装したコードのテストをゼロから書きたいとき。エッジケース・エラーハンドリングもカバー。 |

いずれも Git リポジトリがなくても動作します。

## おすすめの流れ：実装前に設計書を詰める

上記の設計書関連の3コマンドは、**この順番**で使うことを想定しています。それぞれ、下書きを作った会話に引っ張られないよう、新しいセッションで実行してください。

1. Claude Codeに相談しながら設計書の下書きを作る
2. `/ais-local-design-challenge` — そもそもこのアプローチで良いか？ 編集案を出さずに、反論・代替案だけを洗い出す
3. Step 2で出た意見のうち、どれを採用するかを人が決める。その決定に沿って設計書を書き直す作業は、自分で書いてもいいし、決定内容を伝えてAIに書いてもらってもいい。採用の判断自体は、コマンドの外で人が行う
4. `/ais-local-spec-review` — アプローチが固まった状態で、文書自体の整合性・網羅性・明確さをチェックする
5. `/ais-local-design-enhance` — エラー処理・エッジケース・テスト項目など、残った抜け漏れをそのまま挿入できる文章で埋める
6. 実装フェーズへ(ここも新しいセッションで)

アプローチを検証する前に spec-review や design-enhance を実行すると、まだ検証されていない設計をただ磨いてしまうだけになりがちです。
