#!/bin/bash
# Usage: ./scripts/build-release.sh 1.0.0
# Builds a release .app bundle, ad-hoc signs it, and zips it for distribution.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>  (e.g. $0 1.0.0)"
    exit 1
fi

APP_NAME="BrewMenu"
BUILD_DIR=".build/release"
OUT_DIR="build"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"

echo "→ Building ${APP_NAME} ${VERSION} (release)…"
swift build -c release

echo "→ Assembling .app bundle…"
rm -rf "${OUT_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy the SPM resource bundle into Contents/ so Bundle.module can find it at runtime.
# Bundle.module resolves to Bundle.main.bundleURL/BrewMenu_BrewMenu.bundle, which is
# Contents/BrewMenu_BrewMenu.bundle when the binary runs inside the .app.
RESOURCE_BUNDLE="${BUILD_DIR}/BrewMenu_BrewMenu.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/"
fi

cp Sources/Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# Stamp version into the copied plist
cp Sources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${APP_BUNDLE}/Contents/Info.plist"
# CFBundleVersion is the build number — increment manually or automate with git rev-list
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" \
    "${APP_BUNDLE}/Contents/Info.plist"

echo "→ Ad-hoc signing…"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "→ Creating ${ZIP_NAME}…"
(cd "${OUT_DIR}" && zip -qr "${ZIP_NAME}" "${APP_NAME}.app")

SHA=$(shasum -a 256 "${OUT_DIR}/${ZIP_NAME}" | awk '{print $1}')
echo ""
echo "✓ ${OUT_DIR}/${ZIP_NAME}"
echo "  SHA256: ${SHA}"
echo ""
echo "Next steps:"
echo "  1. Create a GitHub release tagged v${VERSION}"
echo "  2. Upload ${ZIP_NAME} as a release asset"
echo "  3. Update the cask formula with version ${VERSION} and sha256 ${SHA}"
