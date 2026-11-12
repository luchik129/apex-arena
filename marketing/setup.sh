#!/usr/bin/env bash
# One-time setup for rendering videos on your computer (macOS or Linux).
set -e
cd "$(dirname "$0")/engine"
command -v node >/dev/null || { echo "Install Node.js 18+ (https://nodejs.org or: brew install node)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "Install ffmpeg (macOS: brew install ffmpeg)"; exit 1; }
python3 -c "import numpy" 2>/dev/null || python3 -m pip install --user numpy
npm install --no-fund --no-audit
npx playwright install chromium
echo "OK: try  cd marketing/engine && OUT_DIR=\$PWD/../data/test node render.js \$PWD/../examples/v01_ranked_gym.json"
