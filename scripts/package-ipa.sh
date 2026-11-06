#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
project_dir=$(pwd)
device_app="$project_dir/build/DeviceDerivedData/Build/Products/Release-iphoneos/Hongguo.app"
if [ ! -f "$device_app/Info.plist" ]; then
    echo "請先執行 sh scripts/build-ios.sh device" >&2
    exit 1
fi
platform_name=$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$device_app/Info.plist")
if [ "$platform_name" != "iphoneos" ]; then
    echo "必須使用 iPhone 實機版本；模擬器 App 不能打包成實機 IPA。" >&2
    exit 1
fi
staging_dir=$(mktemp -d /private/tmp/hongguo-ipa.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
mkdir -p "$staging_dir/Payload" "$project_dir/dist"
ditto --norsrc --noextattr --noqtn "$device_app" "$staging_dir/Payload/Hongguo.app"
app_version=$(cat "$project_dir/VERSION")
built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$device_app/Info.plist")
if [ "$app_version" != "$built_version" ]; then
    echo "App 版本與 VERSION 不符，請重新產生工程並建置實機版本。" >&2
    exit 1
fi
ipa_path="$project_dir/dist/Hongguo-iPhone-$app_version-unsigned.ipa"
ditto --norsrc --noextattr --noqtn -c -k --keepParent "$staging_dir/Payload" "$ipa_path"
echo "$ipa_path"
echo "此 IPA 尚未簽署，需以自己的開發者身分或側載工具簽署後安裝。"
