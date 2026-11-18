#!/bin/bash
# Build build/Dewey.app from mac/ (SwiftPM). Unsigned for distribution: signed ad hoc so macOS will
# run it on the Mac that built it. Usage: scripts/build-app.sh [release|debug]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Dewey.app"

swift build --package-path mac -c "$CONFIG" --product Dewey
BIN="$(swift build --package-path mac -c "$CONFIG" --show-bin-path)/Dewey"

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -1)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dewey"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dewey</string>
  <key>CFBundleDisplayName</key><string>Dewey</string>
  <key>CFBundleExecutable</key><string>Dewey</string>
  <key>CFBundleIdentifier</key><string>io.github.thatcherstudio.dewey</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSDownloadsFolderUsageDescription</key><string>Dewey catalogs and organizes the folders you choose.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Dewey catalogs and organizes the folders you choose.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Dewey catalogs and organizes the folders you choose.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Dewey catalogs and organizes the folders you choose.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Dewey catalogs and organizes the folders you choose.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --verify "$APP"
echo "Built $APP (dewey $VERSION, build $BUILD). Open it: open $APP"
