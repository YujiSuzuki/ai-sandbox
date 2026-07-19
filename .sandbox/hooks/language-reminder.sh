#!/bin/bash
# language-reminder.sh
# Claude Code UserPromptSubmit hook: reinforces CLAUDE.md's "Response Language"
# rule on every prompt, since preceding tool output/code/skill text is often in
# a different language and can otherwise pull responses away from the
# $LANG-derived default. Registered automatically by setup-language-hook.sh
# when the container's locale is Japanese; no-ops for any other locale.
# ---
# Claude Code の UserPromptSubmit フック: 直前のツール出力・コード・スキルの
# テキストが別言語であることが多く、応答が$LANG由来のデフォルト言語から
# ずれてしまうことがあるため、毎プロンプトごとにCLAUDE.mdの「Response
# Language」ルールを再提示する。コンテナのロケールが日本語の場合のみ
# setup-language-hook.sh が自動登録し、それ以外のロケールでは何もしない。

set -euo pipefail

case "${LANG:-}" in
  ja_JP*)
    MSG="Reminder: this session's default response language is Japanese (LANG=ja_JP.UTF-8, per CLAUDE.md's Response Language rule). Apply it to this entire response, including intermediate status updates, even if recent tool output, code, or skill/subagent text was in English. Only switch language if the user message you are replying to is itself written in a different language."
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}' "$MSG"
    ;;
  *)
    printf '{}'
    ;;
esac
