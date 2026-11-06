#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "需要完整 Xcode 與 iOS SDK。安裝後執行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi
if [ ! -f iOS/Hongguo.xcodeproj/project.pbxproj ]; then
    python3 scripts/generate_project.py
fi
case "${1:-simulator}" in
  simulator)
    xcodebuild -project iOS/Hongguo.xcodeproj -scheme Hongguo -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
    ;;
  device)
    xcodebuild -project iOS/Hongguo.xcodeproj -scheme Hongguo -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath build/DeviceDerivedData CODE_SIGNING_ALLOWED=NO build
    ;;
  archive)
    xcodebuild -project iOS/Hongguo.xcodeproj -scheme Hongguo -configuration Release \
      -destination 'generic/platform=iOS' -archivePath build/Hongguo.xcarchive archive
    ;;
  *) echo "用法：scripts/build-ios.sh [simulator|device|archive]" >&2; exit 2 ;;
esac
