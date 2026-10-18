#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${SNAPBAR_OUTPUT_DIR:-$project_dir/dist}"
build_dir="${SNAPBAR_BUILD_DIR:-$project_dir/.build}"
app_dir="$output_dir/轻截.app"
mkdir -p "$build_dir/module-cache" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
build_dir="$(cd "$build_dir" && pwd)"
arch="${SNAPBAR_ARCH:-$(uname -m)}"
compile_arch() {
  xcrun swiftc -O -whole-module-optimization -parse-as-library -module-cache-path "$build_dir/module-cache" \
    -target "$1-apple-macosx13.0" -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
    "$project_dir"/Sources/*.swift -o "$2"
}
if [ "$arch" = "universal" ]; then
  compile_arch x86_64 "$build_dir/SnapBar-x86_64"
  compile_arch arm64 "$build_dir/SnapBar-arm64"
  xcrun lipo -create "$build_dir/SnapBar-x86_64" "$build_dir/SnapBar-arm64" -output "$app_dir/Contents/MacOS/SnapBar"
else
  compile_arch "$arch" "$app_dir/Contents/MacOS/SnapBar"
fi
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
if [ ! -f "$project_dir/AppIcon.icns" ]; then
  xcrun swift -module-cache-path "$build_dir/module-cache" "$project_dir/MakeIcon.swift" "$build_dir/AppIcon.iconset" "$project_dir/AppIcon.icns"
fi
cp "$project_dir/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.local.SnapBar "$app_dir"
echo "已构建：$app_dir"
