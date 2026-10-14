#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -c release
rm -rf Stenographer.app
mkdir -p Stenographer.app/Contents/MacOS
cp .build/release/Stenographer Stenographer.app/Contents/MacOS/
cp Info.plist Stenographer.app/Contents/
mkdir -p Stenographer.app/Contents/Resources
xcrun actool AppIcon.icon --compile Stenographer.app/Contents/Resources --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist /dev/null >/dev/null
# A stable identity keeps mic/audio/Notes permissions across rebuilds; ad-hoc (-s -) re-prompts every build,
# and the prompt blocks Start behind the hourglass.
codesign --force -s "Apple Development: Anastasios Sangiotis (NP5X9VJ3S5)" Stenographer.app
pkill -x Stenographer || true
sleep 1
rm -rf /Applications/Stenographer.app
ditto Stenographer.app /Applications/Stenographer.app
echo "Installed /Applications/Stenographer.app"
