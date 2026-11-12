#!/bin/sh
# Copies the YouTube engine (the same files the web app uses) into the iOS app's Engine folder.
# The cloud build runs this first; run it yourself before opening the project locally.
set -e
cd "$(dirname "$0")/.."
rm -rf Engine/js Engine/vendor
mkdir -p Engine/js/engine Engine/vendor
cp ../frontend/js/engine/*.js Engine/js/engine/
cp ../frontend/vendor/youtubei.js ../frontend/vendor/youtubei.LICENSE.txt Engine/vendor/
echo "Engine copied: $(ls Engine/js/engine | wc -l) files plus youtubei.js"
