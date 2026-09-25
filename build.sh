#!/bin/zsh
# Builds AccessibleName.app into ./build
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AccessibleName"

APP=build/AccessibleName.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AccessibleName"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.AccessibleName</string>
    <key>CFBundleName</key><string>AccessibleName</string>
    <key>CFBundleExecutable</key><string>AccessibleName</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a real identity when available so the Accessibility permission survives
# rebuilds (ad-hoc signatures change every build, and macOS then treats it as a new app).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -oE '"(Apple Development|Developer ID Application): [^"]+"' | tr -d '"' || true)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"
