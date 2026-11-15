#!/bin/bash
# Local CI: builds every target, runs the tests, bundles Decanter.app and packages it as a zip.
# Exits non-zero at the first failure. Run by the pre-push hook and by release.sh.
#
#   Scripts/ci.sh            build, test, bundle, package into dist/
#   Scripts/ci.sh --quick    build and test only (what the pre-push hook runs)
set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
START=$SECONDS

step "Build (debug, all targets)"
swift build --build-tests

step "Test"
swift test --skip-build

if [ $QUICK -eq 1 ]; then
    printf '\n\033[32m✓ CI passed (quick) in %ss\033[0m\n' $((SECONDS - START))
    exit 0
fi

step "Bundle (release)"
Scripts/bundle.sh
APP="build/Decanter.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

step "Verify bundle"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict --verbose=1 "$APP"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || { echo "AppIcon.icns is missing"; exit 1; }
file "$APP/Contents/MacOS/Decanter"

step "Package"
mkdir -p dist
ZIP="dist/Decanter-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the code signature and extended attributes that zip(1) would drop.
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

printf '\n\033[32m✓ CI passed in %ss → %s\033[0m\n' $((SECONDS - START)) "$ZIP"
