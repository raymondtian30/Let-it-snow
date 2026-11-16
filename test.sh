#!/bin/zsh
# Build the app, then run the tests: updater (versions, release JSON, unzip/replace a real release zip) and snowball physics
set -euo pipefail
cd "$(dirname "$0")"
zsh build.sh --zip
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
swiftc Sources/LetItSnow.swift Sources/Updater.swift Tests/*.swift -o build/Tests
build/Tests "build/LetItSnow-$VERSION.zip"
