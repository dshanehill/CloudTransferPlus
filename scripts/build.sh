#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
swift build -c release --scratch-path "${CLOUD_TRANSFER_BUILD_DIR:-$PROJECT_DIR/.build}"
APP_DIR="${CLOUD_TRANSFER_APP_DIR:-$PROJECT_DIR/.build/bundle/Cloud Transfer+.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "${CLOUD_TRANSFER_BUILD_DIR:-$PROJECT_DIR/.build}/release/CloudHarbor" "$APP_DIR/Contents/MacOS/CloudTransferPlus"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Cloud Transfer+</string>
<key>CFBundleDisplayName</key><string>Cloud Transfer+</string>
<key>CFBundleExecutable</key><string>CloudTransferPlus</string>
<key>CFBundleIdentifier</key><string>com.cloudtransferplus.mac</string>
<key>CFBundleVersion</key><string>23</string>
<key>CFBundleShortVersionString</key><string>0.9.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ -d "$PROJECT_DIR/scripts/AppIcon.iconset" ]]; then
  iconutil -c icns "$PROJECT_DIR/scripts/AppIcon.iconset" -o "$PROJECT_DIR/scripts/AppIcon.icns"
fi
if [[ -f "$PROJECT_DIR/scripts/AppIcon.icns" ]]; then
  cp "$PROJECT_DIR/scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
