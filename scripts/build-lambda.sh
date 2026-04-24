#!/usr/bin/env bash
# Build the Lambda deployment zip.
# Uses pip --platform manylinux2014_x86_64 so the package works on Lambda's Linux runtime
# even when built from macOS arm64. Requires Python 3.12 + pip >= 22.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAMBDA_DIR="$ROOT/terraform/lambda"
BUILD_DIR="$LAMBDA_DIR/build"
PKG_DIR="$BUILD_DIR/package"
ZIP="$BUILD_DIR/lambda.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR"

PIP="${PIP:-pip3}"
if ! command -v "$PIP" >/dev/null 2>&1; then
  PIP="python3 -m pip"
fi

echo "==> Installing dependencies for Linux Lambda runtime (using: $PIP)"
$PIP install \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --target "$PKG_DIR" \
  -r "$LAMBDA_DIR/requirements.txt"

echo "==> Building zip"
cd "$PKG_DIR"
zip -q -r "$ZIP" .
cd "$LAMBDA_DIR"
zip -q -j "$ZIP" handler.py

SIZE=$(du -h "$ZIP" | cut -f1)
echo "==> Built $ZIP ($SIZE)"
