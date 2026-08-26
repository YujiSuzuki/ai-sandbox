#!/bin/bash
# language-reminder.sh
# Claude Code UserPromptSubmit hook: reinforces CLAUDE.md's "Response Language"
# rule on every prompt, since preceding tool output/code/skill/nested-project-doc
# text is often in a different language and can otherwise pull responses away
# from the $LANG-derived default -- in either direction. Registered
# automatically by setup-language-hook.sh regardless of locale.
# ---
# Claude Code の UserPromptSubmit フック: 直前のツール出力・コード・スキル・
# ネストしたプロジェクトのドキュメントが別言語であることが多く、応答が
# $LANG由来のデフォルト言語からずれてしまうことがある（どちらの方向にも
# 起こりうる）ため、毎プロンプトごとにCLAUDE.mdの「Response Language」
# ルールを再提示する。ロケールによらず setup-language-hook.sh が自動登録する。

set -euo pipefail

case "${LANG:-}" in
  ja_JP*)
    MSG="Reminder: this session's default response language is Japanese (LANG=ja_JP.UTF-8, per CLAUDE.md's Response Language rule). Apply it to this entire response, including intermediate status updates, even if recent tool output, code, or skill/subagent text was in English. Only switch language if the user message you are replying to is itself written in a different language."
    ;;
  *)
    MSG="Reminder: this session's default response language is English (LANG=${LANG:-unset}, per CLAUDE.md's Response Language rule). Apply it to this entire response, including intermediate status updates, even if recent tool output, file contents, or nested project docs (e.g. Japanese README excerpts) were in Japanese. Only switch language if the user message you are replying to is itself written in a different language."
    ;;
esac
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}' "$MSG"
