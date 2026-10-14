#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -c release
rm -rf Stenographer.app
mkdir -p Stenographer.app/Contents/MacOS
cp .build/release/Stenographer Stenographer.app/Contents/MacOS/
cp Info.plist Stenographer.app/Contents/
# ponytail: ad-hoc signature, so macOS re-asks for permissions after each rebuild; sign with a Developer ID to stop that
codesign --force -s - Stenographer.app
pkill -x Stenographer || true
rm -rf /Applications/Stenographer.app
ditto Stenographer.app /Applications/Stenographer.app
echo "Installed /Applications/Stenographer.app"
