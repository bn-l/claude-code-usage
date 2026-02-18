# Build commands for Clacal app

# Default recipe: build the app bundle
default: app

# Build Clacal.app bundle to ./build/
app:
    @mkdir -p build
    xcodebuild -project Clacal.xcodeproj -scheme Clacal -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
    @rm -rf build/Clacal.app
    @cp -R ~/Library/Developer/Xcode/DerivedData/Clacal-*/Build/Products/Debug/Clacal.app build/

# Build release app bundle
app-release:
    @mkdir -p build
    xcodebuild -project Clacal.xcodeproj -scheme Clacal -configuration Release -destination 'platform=macOS,arch=arm64' -quiet
    @rm -rf build/Clacal.app
    @cp -R ~/Library/Developer/Xcode/DerivedData/Clacal-*/Build/Products/Release/Clacal.app build/

# Regenerate Xcode project from project.yml
gen:
    xcodegen generate

# Clean build artifacts
clean:
    rm -rf build .build
    xcodebuild -project Clacal.xcodeproj -scheme Clacal clean -quiet 2>/dev/null || true

# Run the app
run: app
    open build/Clacal.app

# Run tests
test:
    xcodebuild test -project Clacal.xcodeproj -scheme Clacal -destination 'platform=macOS,arch=arm64'

# Clear all data from the database
clear-db:
    rm -f ~/.config/clacal/history.db
    rm -f ~/.config/clacal/history-v2.store
    rm -f ~/.config/clacal/history-v2.store-shm
    rm -f ~/.config/clacal/history-v2.store-wal

# Print version from Info.plist
version:
    @/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist

# Create DMG from release build
dmg: app-release
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/Clacal_${VERSION}.dmg"
    rm -f "$DMG"
    hdiutil create "$DMG" -volname "Clacal" -srcfolder build/Clacal.app -ov -format UDZO
    echo "$DMG"

# Create GitHub release with DMG
release: dmg
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/Clacal_${VERSION}.dmg"
    SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
    gh release create "v${VERSION}" "$DMG" --title "Clacal v${VERSION}" --notes "See assets to download and install."
    echo ""
    echo "SHA256: ${SHA}"
    echo "Update homebrew-tap/Casks/clacal.rb with version \"${VERSION}\" and sha256 \"${SHA}\""
