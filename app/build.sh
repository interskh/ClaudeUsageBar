#!/bin/bash

# Build script for ClaudeUsageBar

# Fail loudly: a compile error must never reach "Build successful!" with a stale
# binary still sitting in build/. This script is the verification gate for the
# whole multi-provider migration, so a silent success is worse than no build.
set -euo pipefail

# All paths below are relative to this script, so it can be invoked from anywhere
# (e.g. `bash app/build.sh` from the repo root).
cd "$(dirname "$0")"

# Source layout. Adding a .swift file to one of these directories is picked up by
# both targets with no edit here.
#   PURE_DIRS     — pure logic (parsing, discovery, classification, worst-of).
#                   Compiled into the app target whole, and into the test target
#                   MINUS APP_ONLY_FILES. §9's layout puts a few impure files in
#                   these directories (the Keychain reader, the real filesystem);
#                   everything the test target compiles must stay free of
#                   networking, Keychain and SwiftUI (§10), which the purity
#                   check below enforces rather than trusting.
#   APP_ONLY_DIRS — SwiftUI/AppKit views, the account store, the @main entry
#                   point. App target only; the test target must not link them.
#   TEST_DIRS     — the test runner and its harness. Test target only.
PURE_DIRS=(Model Providers Credentials)
APP_ONLY_DIRS=(App Core UI)
TEST_DIRS=(Tests)

# Individual files that §9's layout places inside a PURE dir but which are NOT pure:
# the Keychain reader, the concrete filesystem that reads the real home directory and
# environment, the networking client, and the subprocess that probes the installed CLI
# for its version. All are excluded by name from the test compile rather than moved,
# so the source layout stays as §9 specifies and the exclusion is stated where the
# target sets are rather than hidden in an import. Tests reach the same behaviour
# through the pure ClaudeCredentialSource / ProfileFileSystem protocols with fakes, so
# the test target can touch neither the real Keychain nor the developer's home even by
# mistake. Paths are relative to app/.
APP_ONLY_FILES=(
    Credentials/KeychainStore.swift
    Credentials/SystemProfileFileSystem.swift
    Providers/FoundationHTTPClient.swift
    Providers/InstalledAgentVersionProbe.swift
)

# Dependencies that must never appear in the sources the TEST target compiles (§10).
# The exclusion list above is hand-maintained and will rot as tasks 5-6 add files to
# Credentials/ and Providers/; this check does not, so purity stays self-enforcing.
IMPURE_PATTERNS='usr/bin/security|SecItem|import Security|URLSession|import SwiftUI|import AppKit|NSHomeDirectory|ProcessInfo|Process\('

# Fills the FOUND array with absolute paths to the .swift files in the given
# directories, minus anything listed in EXCLUDED (relative to app/). Absolute
# (rather than relative) so that #filePath in the test harness resolves without
# depending on the runtime working directory, and so nothing word-splits on a
# path containing a space.
FOUND=()
EXCLUDED=()
collect_swift() {
    FOUND=()
    local dir file skip excluded
    for dir in "$@"; do
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' file; do
            skip=0
            for excluded in ${EXCLUDED[@]+"${EXCLUDED[@]}"}; do
                [ "$file" = "$PWD/$excluded" ] && skip=1
            done
            [ "$skip" -eq 1 ] || FOUND+=("$file")
        done < <(find "$PWD/$dir" -name '*.swift' -print0 | LC_ALL=C sort -z)
    done
}

# --test: compile and run the pure-logic test target. Networking, Keychain and
# SwiftUI stay out by construction — only PURE_DIRS and TEST_DIRS are compiled.
if [ "${1:-}" = "--test" ]; then
    echo "Building test target..."
    mkdir -p build
    # A typo in APP_ONLY_FILES would silently link the Keychain into the test
    # target, which is precisely what the list exists to prevent. Fail loud.
    for excluded in "${APP_ONLY_FILES[@]}"; do
        if [ ! -f "$excluded" ]; then
            echo "❌ APP_ONLY_FILES lists a file that does not exist: $excluded"
            exit 1
        fi
    done
    EXCLUDED=("${APP_ONLY_FILES[@]}")
    collect_swift "${PURE_DIRS[@]}" "${TEST_DIRS[@]}"
    EXCLUDED=()
    if [ ${#FOUND[@]} -eq 0 ]; then
        echo "❌ No test sources found"
        exit 1
    fi
    if IMPURE=$(grep -lE "$IMPURE_PATTERNS" "${FOUND[@]}"); then
        echo "❌ Test target sources reference an impure dependency (§10):"
        echo "$IMPURE" | sed 's|^|   |'
        echo "   Move the file to an APP_ONLY dir, or add it to APP_ONLY_FILES."
        exit 1
    fi
    swiftc -o build/ClaudeUsageBarTests "${FOUND[@]}"
    ./build/ClaudeUsageBarTests
    exit 0
fi

echo "Building ClaudeUsageBar..."

# Create build directory
mkdir -p build

collect_swift "${PURE_DIRS[@]}" "${APP_ONLY_DIRS[@]}"
if [ ${#FOUND[@]} -eq 0 ]; then
    echo "❌ No Swift sources found"
    exit 1
fi
SOURCES=("${FOUND[@]}")

# Create app bundle structure first
APP_NAME="ClaudeUsageBar.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp Info.plist "$APP_PATH/Contents/"

# Create icon if it doesn't exist
if [ ! -f "ClaudeUsageBar.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null 2>&1 || true
fi

# Copy icon to Resources
if [ -f "ClaudeUsageBar.icns" ]; then
    cp ClaudeUsageBar.icns "$APP_PATH/Contents/Resources/"
    # Update Info.plist to reference icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ClaudeUsageBar" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ClaudeUsageBar" "$APP_PATH/Contents/Info.plist"
fi

# Compile the Swift app for arm64
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    "${SOURCES[@]}" \
    -framework SwiftUI \
    -framework AppKit \
    -target arm64-apple-macos12.0

# Compile for x86_64 (Intel)
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" \
    "${SOURCES[@]}" \
    -framework SwiftUI \
    -framework AppKit \
    -target x86_64-apple-macos12.0

# Create universal binary
lipo -create -output "$APP_PATH/Contents/MacOS/ClaudeUsageBar" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Clean up individual arch binaries
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64"
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Create PkgInfo file
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Set proper permissions first
chmod 755 "$APP_PATH/Contents/MacOS/ClaudeUsageBar"

# Clean extended attributes before signing
xattr -cr "$APP_PATH" || true

# Sign with Developer ID certificate
DEVELOPER_ID="Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)"
if codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_PATH" 2>/dev/null; then
    echo "✅ App signed with Developer ID"
else
    echo "⚠️  Falling back to ad-hoc signature"
    codesign --force --deep --sign - "$APP_PATH"
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
echo "Launching app..."
open "$APP_PATH"
