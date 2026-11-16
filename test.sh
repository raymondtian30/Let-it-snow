#!/bin/zsh
# Build the app, then run the updater tests (version compare, release JSON, unzipping a real release zip)
set -euo pipefail
cd "$(dirname "$0")"
zsh build.sh --zip
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
swiftc Sources/Updater.swift Tests/main.swift -o build/UpdaterTests
build/UpdaterTests "build/LetItSnow-$VERSION.zip"
