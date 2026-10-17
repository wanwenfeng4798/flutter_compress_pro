#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p example/assets
if command -v ffmpeg >/dev/null; then
  ffmpeg -y -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=4' -c:v libx264 -b:v 2M -pix_fmt yuv420p example/assets/sample.mp4
elif [ "$(uname -s)" = Darwin ]; then
  bash tool/run_darwin_checks.sh example/assets/sample.mp4 --fixture-only
else
  echo 'Install FFmpeg to generate the integration fixture.' >&2
  exit 1
fi
