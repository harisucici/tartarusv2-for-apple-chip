#!/bin/zsh
set -eu
cd "${0:A:h}"

task_cache="$PWD/.build"
task_app="$PWD/build/Tartarus Light.app"
mkdir -p "$task_cache/tmp" "$task_cache/modules" "$task_app/Contents/MacOS"
export TMPDIR="$task_cache/tmp"

# --- Version generation: YYYY-MM-DD-vN format ---
TODAY=$(date +%Y-%m-%d)
VERSION_FILE="$PWD/version.txt"
if [[ -f "$VERSION_FILE" ]]; then
    stored_date=$(cut -d' ' -f1 < "$VERSION_FILE")
    stored_count=$(cut -d' ' -f2 < "$VERSION_FILE")
    if [[ "$stored_date" == "$TODAY" ]]; then
        count=$((stored_count + 1))
    else
        count=1
    fi
else
    count=1
fi
echo "$TODAY $count" > "$VERSION_FILE"
APP_VERSION="${TODAY}-v${count}"
print "Version: $APP_VERSION"

# Generate VersionInfo.swift so the app can display the build version at runtime
cat > "$task_cache/VersionInfo.swift" <<SWIFT
enum VersionInfo {
    static let version = "$APP_VERSION"
}
SWIFT

xcrun clang -target arm64-apple-macos13.0 -fmodules-cache-path="$task_cache/modules" \
    -c Sources/USBTransport.c -o "$task_cache/USBTransport.o"
xcrun swiftc -target arm64-apple-macos13.0 -module-cache-path "$task_cache/modules" \
    -import-objc-header Sources/USBTransport.h -parse-as-library \
    Sources/Main.swift Sources/LightController.swift Sources/LightView.swift Sources/Theme.swift \
    Sources/StartupController.swift Sources/CoreChecks.swift Sources/MappingEngine.swift \
    Sources/MappingController.swift Sources/MappingView.swift Sources/MappingChecks.swift \
    Sources/PrivilegedInput.swift Sources/RootHelper.swift Sources/IPC.swift Sources/DeviceScope.swift \
    "$task_cache/VersionInfo.swift" \
    "$task_cache/USBTransport.o" -o "$task_app/Contents/MacOS/TartarusLight" \
    -framework Cocoa -framework SwiftUI -framework IOKit -framework ServiceManagement \
    -framework ApplicationServices -framework SystemConfiguration

mkdir -p "$task_app/Contents/Resources"
for lproj in Sources/en.lproj Sources/zh-Hans.lproj Sources/zh-Hant.lproj Sources/ja.lproj; do
    task_locale="$task_app/Contents/Resources/$(basename "$lproj")"
    rm -rf "$task_locale"
    cp -R "$lproj" "$task_locale"
done

rm -f "$task_cache/Info.plist"
/usr/bin/plutil -create xml1 "$task_cache/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string TartarusLight "$task_cache/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string local.tartarus.light "$task_cache/Info.plist"
/usr/bin/plutil -insert CFBundleName -string 'Tartarus Light' "$task_cache/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string 'Tartarus Light' "$task_cache/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$APP_VERSION" "$task_cache/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$task_cache/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$task_cache/Info.plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "$task_cache/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$task_cache/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool YES "$task_cache/Info.plist"
/usr/bin/plutil -insert NSInputMonitoringUsageDescription -string 'Tartarus Light reads only the selected Tartarus V2 for key identification and device-specific remapping.' "$task_cache/Info.plist"
cp "$task_cache/Info.plist" "$task_app/Contents/Info.plist"

codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
if [[ "$(uname -m)" == arm64 ]]; then
    "$task_app/Contents/MacOS/TartarusLight" --self-test
else
    print 'Built for Apple Silicon. Run --self-test on an Apple Silicon Mac.'
fi
print "Built: $task_app"
