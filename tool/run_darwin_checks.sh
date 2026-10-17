#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tool/.build
sources=()
for source in darwin/flutter_compress_pro/Sources/flutter_compress_pro/*.swift; do
  case "$source" in */FlutterCompressPlugin.swift) continue ;; esac
  sources+=("$source")
done
swiftc -module-cache-path tool/.build/modules "${sources[@]}" tool/darwin_regression.swift -o tool/.build/darwin-regression
tool/.build/darwin-regression "${1:-example/assets/sample.mp4}" "${2:-}"
