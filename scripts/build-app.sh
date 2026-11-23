#!/bin/bash
# Build build/Dewey.app from mac/ (SwiftPM), with its own Python and dewey inside, so it needs
# nothing else installed, and a copy of uv for its Install Laya button (Laya itself downloads into
# ~/Library/Application Support/Dewey). Unsigned for distribution: signed ad hoc so macOS will run
# it on the Mac that built it. Needs uv. Usage: scripts/build-app.sh [release|debug]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Dewey.app"
PY="3.12"

command -v uv >/dev/null || { echo "Building Dewey.app needs uv (brew install uv)." >&2; exit 1; }
UV="$(realpath "$(command -v uv)")"
# The app runs this uv on its own, so it must need nothing but macOS (Homebrew's and uv's own
# installer's builds both do). A uv linked against other libraries would break once they change.
if otool -L "$UV" | tail -n +2 | grep -qvE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
    echo "$UV links libraries outside macOS; install uv with brew or its installer." >&2
    exit 1
fi

swift build --package-path mac -c "$CONFIG" --product Dewey
BIN="$(swift build --package-path mac -c "$CONFIG" --show-bin-path)/Dewey"

# The Python inside the app: uv's standalone CPython (it runs from any folder), trimmed, with dewey
# and its extras installed into it. Kept in build/python between builds; only dewey is reinstalled.
uv python install "$PY" --quiet  # a download the first time (about 20 MB), then nothing
PYHOME="$(cd "$(dirname "$(realpath "$(uv python find --managed-python "$PY")")")/.." && pwd)"
STAGE="build/python"
if [ "$(cat build/python.from 2>/dev/null)" != "$PYHOME" ]; then
    rm -rf "$STAGE" build/python.from
    ditto "$PYHOME" "$STAGE"
    # what dewey never uses: Tk, IDLE, pip (uv installs), headers, libpython (python3 has it built in)
    (cd "$STAGE" && rm -rf include share lib/pkgconfig lib/tcl* lib/tk* lib/itcl* lib/thread* \
        lib/libtcl* lib/libpython* bin/2to3* bin/idle* bin/pip* bin/pydoc* bin/python*-config \
        lib/python$PY/{idlelib,tkinter,turtledemo,turtle.py,ensurepip,lib2to3,EXTERNALLY-MANAGED} \
        lib/python$PY/lib-dynload/_tkinter* lib/python$PY/site-packages/pip*)
    echo "$PYHOME" > build/python.from
fi
# constraints.txt names the one version of each package that goes in, with the checksums of its
# files: a build next month bundles what was tested, not what was released that morning. A pin
# that no longer fits pyproject.toml, or a file that doesn't match its checksum, stops the build
# here. `make pins` moves them forward.
uv pip install --quiet --python "$STAGE/bin/python3" --reinstall-package dewey -c constraints.txt '.[all]'
# .pyc files that never check their source: the app runs Python with -B, so nothing is written
# into the signed bundle, and nothing is compiled again at each start.
"$STAGE/bin/python3" -I -m compileall -q -j0 --invalidation-mode unchecked-hash "$STAGE/lib" >/dev/null

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -1)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dewey"
cp mac/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # drawn by scripts/make-icon.swift
ditto "$STAGE" "$APP/Contents/Resources/python"
mkdir -p "$APP/Contents/Resources/bin"
# The dewey the app runs (and you can too, or link it into your PATH). -I ignores PYTHON* variables
# and your own site-packages, so it passes -u (unbuffered) and -X utf8 itself.
cat > "$APP/Contents/Resources/bin/dewey" <<'SH'
#!/bin/sh
exec "$(dirname "$(realpath "$0")")/../python/bin/python3" -I -B -u -X utf8 -m dewey "$@"
SH
chmod 755 "$APP/Contents/Resources/bin/dewey"
# For Setup's Install Laya button (LayaInstaller.swift). About 30 MB.
cp "$UV" "$APP/Contents/Resources/bin/uv"
chmod 755 "$APP/Contents/Resources/bin/uv"

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

# codesign says "replacing existing signature" each time it works, so what it prints is kept back
# and shown only when it fails. 0.2.1 threw it away, and a build that couldn't be signed stopped
# here without a word.
if ! signing="$(codesign --force --sign - "$APP" 2>&1)"; then
    echo "Couldn't sign $APP:" >&2
    echo "$signing" >&2
    exit 1
fi
codesign --verify "$APP"
echo "Built $APP (dewey $VERSION, uv $("$APP/Contents/Resources/bin/uv" --version | cut -d' ' -f2), build $BUILD). Open it: open $APP"
