#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
app_path="${1:-$project_dir/dist/轻截.app}"
output_dir="${2:-$project_dir/Installers}"
package_build_dir="${SNAPBAR_PACKAGE_BUILD_DIR:-$project_dir/.build/package}"

if [ ! -d "$app_path" ] || [ ! -f "$app_path/Contents/Info.plist" ]; then
  echo "找不到轻截 App。请先运行 ./build.sh，或传入 App 路径。" >&2
  exit 1
fi
app_path="$(cd "$app_path" && pwd)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Contents/Info.plist")"
if [ "$bundle_id" != "com.local.SnapBar" ]; then
  echo "App 标识不是 com.local.SnapBar，请确认打包对象。" >&2
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9][0-9A-Za-z.+-]*$ ]]; then
  echo "App 版本号不适合用作安装包文件名。" >&2
  exit 1
fi
codesign --verify --deep --strict "$app_path"
architectures="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/SnapBar")"
case "$architectures" in
  *x86_64*arm64*|*arm64*x86_64*) architecture=universal ;;
  arm64) architecture=arm64 ;;
  x86_64) architecture=x86_64 ;;
  *) echo "无法识别 App 的 CPU 架构：$architectures" >&2; exit 1 ;;
esac

mkdir -p "$output_dir" "$package_build_dir"
output_dir="$(cd "$output_dir" && pwd)"
stage="$(mktemp -d "$package_build_dir/stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

/usr/bin/ditto "$app_path" "$stage/轻截.app"
/bin/ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明.txt" <<'GUIDE'
SnapBar · 轻截

安装：
1. 将「轻截.app」拖到旁边的「Applications」（应用程序）文件夹。
2. 如果已安装旧版，请先从轻截菜单中退出 App，再选择替换。
3. 推出此磁盘映像，然后从「应用程序」打开「轻截」。
4. 运行后，屏幕顶部菜单栏会出现取景框图标。

使用：
默认截图快捷键为 Control + Shift + A，可以在设置中修改。
框选后支持标注、复制，以及保存为本地 PNG/JPG 文件。

首次截图：
请在「系统设置 → 隐私与安全性 → 屏幕录制」允许轻截。
按系统提示退出并重新打开 App，再开始截图。

当前 App 采用本地临时签名，尚未做 Apple 公证。
若系统阻止首次打开，确认下载来源后，可右键 App → 打开；
较新的 macOS 可在「系统设置 → 隐私与安全性」选择「仍要打开」。

需要 macOS 13 或以上。
项目与权限排错：https://github.com/danchaofan/snapbar
GUIDE

name="SnapBar-$version-macOS-$architecture.dmg"
/usr/bin/hdiutil create -volname "SnapBar $version" -srcfolder "$stage" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$output_dir/$name"
/usr/bin/hdiutil verify "$output_dir/$name"
(
  cd "$output_dir"
  LC_ALL=C /usr/bin/shasum -a 256 "$name" > "$name.sha256"
)
echo "安装包：$output_dir/$name"
echo "校验文件：$output_dir/$name.sha256"
