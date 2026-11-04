#!/bin/zsh
# 用法：./build.sh   → 產生 Comma.app（先跑 CSV 自我測試）
set -e
cd "${0:A:h}"
swiftc -swift-version 5 CSV.swift test/main.swift -o /tmp/comma-selftest
/tmp/comma-selftest
APP=Comma.app
rm -rf $APP && mkdir -p $APP/Contents/{MacOS,Resources/zh-Hant.lproj}
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.4 App.swift CSV.swift -o $APP/Contents/MacOS/Comma
cp Info.plist $APP/Contents/
cp -R web $APP/Contents/Resources/
cp icon/Comma.icns $APP/Contents/Resources/
codesign --force --deep -s - $APP
echo "完成：$PWD/$APP"
