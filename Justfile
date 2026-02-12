# Build commands for ClaudeCodeUsage app

# Default recipe: build the app bundle
default: app

# Build ClaudeCodeUsage.app bundle to ./build/
app:
    @mkdir -p build
    xcodebuild -project ClaudeCodeUsage.xcodeproj -scheme ClaudeCodeUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
    @rm -rf build/ClaudeCodeUsage.app
    @cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeCodeUsage-*/Build/Products/Debug/ClaudeCodeUsage.app build/

# Build release app bundle
app-release:
    @mkdir -p build
    xcodebuild -project ClaudeCodeUsage.xcodeproj -scheme ClaudeCodeUsage -configuration Release -destination 'platform=macOS,arch=arm64' -quiet
    @rm -rf build/ClaudeCodeUsage.app
    @cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeCodeUsage-*/Build/Products/Release/ClaudeCodeUsage.app build/

# Regenerate Xcode project from project.yml
gen:
    xcodegen generate

# Clean build artifacts
clean:
    rm -rf build .build
    xcodebuild -project ClaudeCodeUsage.xcodeproj -scheme ClaudeCodeUsage clean -quiet 2>/dev/null || true

# Run the app
run: app
    open build/ClaudeCodeUsage.app
