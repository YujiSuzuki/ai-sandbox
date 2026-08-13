#!/bin/bash
# xcodegen-generate.sh
# Generate an .xcodeproj from an XcodeGen project.yml spec (host OS execution).
# Requires XcodeGen on the host: `brew install xcodegen`.
#
# Usage:
#   xcodegen-generate.sh <project.yml> [-- <extra xcodegen args>]
#
# Examples:
#   xcodegen-generate.sh /path/to/project.yml
#   xcodegen-generate.sh ./project.yml -- --use-cache
# ---
# XcodeGen の project.yml から .xcodeproj をホスト OS 上で生成する汎用スクリプトです。
# ホスト側に事前に XcodeGen が必要です: `brew install xcodegen`

set -e

SPEC_FILE="$1"
shift || true

if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
    echo "Error: project.yml spec not found: ${SPEC_FILE:-<none>}" >&2
    echo "Usage: xcodegen-generate.sh <project.yml> [-- <extra xcodegen args>]" >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: xcodegen not found on host. Install it with: brew install xcodegen" >&2
    exit 1
fi

SPEC_DIR="$(cd "$(dirname "$SPEC_FILE")" && pwd)"

echo "Generating Xcode project..."
echo "  Spec: $SPEC_FILE"
xcodegen generate --spec "$SPEC_FILE" --project "$SPEC_DIR" "$@"

echo ""
echo "Done. Project generated in: $SPEC_DIR"
