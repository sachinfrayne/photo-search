#!/bin/bash
# Builds PhotoSearch.app — run this on an Apple Silicon Mac with the Xcode
# Command Line Tools (`xcode-select --install` if `swift build` isn't found).
# Output: dist/PhotoSearch.app and dist/PhotoSearch.dmg
set -e
cd "$(dirname "$0")"

APP_NAME="PhotoSearch"
BUNDLE_ID="com.sachinfrayne.photosearch"
VERSION="1.0.0"
BUILD_DIR="dist"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

./scripts/fetch_deps.sh

echo "Building $APP_NAME (release)..."
swift build -c release --arch arm64

echo "Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/models"
cp ".build/arm64-apple-macosx/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp vendor/qdrant "$APP_BUNDLE/Contents/MacOS/qdrant"
cp -R vendor/models/mobileclip_s2_image.mlpackage vendor/models/mobileclip_s2_text.mlpackage \
      vendor/models/clip-vocab.json vendor/models/clip-merges.txt "$APP_BUNDLE/Contents/Resources/models/"
cp icon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp packaging/THIRD_PARTY_NOTICES.txt "$APP_BUNDLE/Contents/Resources/"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc — no paid Apple Developer account needed)..."
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/qdrant"
codesign --force --sign - "$APP_BUNDLE"

echo "Creating DMG..."
rm -rf "$BUILD_DIR/dmg-staging"
mkdir -p "$BUILD_DIR/dmg-staging"
cp -R "$APP_BUNDLE" "$BUILD_DIR/dmg-staging/"
cp "packaging/FIRST TIME ON MAC.txt" "$BUILD_DIR/dmg-staging/"
ln -s /Applications "$BUILD_DIR/dmg-staging/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-staging" -ov -format UDZO "$BUILD_DIR/$APP_NAME.dmg"
rm -rf "$BUILD_DIR/dmg-staging"

echo ""
echo "Done: $BUILD_DIR/$APP_NAME.dmg"
