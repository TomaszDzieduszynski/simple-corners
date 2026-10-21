#!/bin/sh
# Builds dist/simple_corners_v<version>.rbz from src/.
# Usage: sh scripts/build_rbz.sh
set -e
cd "$(dirname "$0")/.."
VERSION=$(sed -n "s/.*VERSION = '\([0-9.]*\)'.*/\1/p" src/simple_corners.rb)
OUT="dist/simple_corners_v${VERSION}.rbz"
mkdir -p dist
rm -f "$OUT"
cd src
zip -X -r "../$OUT" simple_corners.rb simple_corners -x '*.DS_Store' >/dev/null
cd ..
echo "Built $OUT"
unzip -l "$OUT"
