#!/bin/bash
# @output: file  (see https://github.com/YujiSuzuki/sandbox-mcp/blob/main/README.md#setup-scripts-sandboxsandbox-mcp-setup)
# Tell the AI which language to respond in
# ---
# AIにどの言語で応答すべきかを伝える

if [ "$LANG" = "ja_JP.UTF-8" ]; then
  echo "Response language: default to Japanese (LANG=ja_JP.UTF-8), but always match whatever language the user actually writes in."
else
  echo "Response language: default to English (LANG=${LANG:-unset}), but always match whatever language the user actually writes in."
fi
