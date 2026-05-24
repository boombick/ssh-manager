#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Always start from a fresh release build of the .app
./scripts/build-app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier'     Resources/Info.plist)"

PKG_ROOT="build/pkg-root"
PKG_OUT="SSHManager-${VERSION}.pkg"

echo "==> staging into ${PKG_ROOT}"
rm -rf "${PKG_ROOT}"
mkdir -p "${PKG_ROOT}/Applications"
# ditto skips resource forks / xattrs so we don't end up with AppleDouble (._*) files
# in the pkg payload.
ditto --norsrc --noextattr --noacl SSHManager.app "${PKG_ROOT}/Applications/SSHManager.app"
# Re-apply the ad-hoc signature (it lives inside the Mach-O, but the bundle's
# _CodeSignature/CodeResources references xattrs we just stripped).
codesign --force --sign - "${PKG_ROOT}/Applications/SSHManager.app" >/dev/null 2>&1 || true

echo "==> pkgbuild → ${PKG_OUT}"
pkgbuild \
  --root "${PKG_ROOT}" \
  --identifier "${IDENTIFIER}" \
  --version "${VERSION}" \
  --install-location "/" \
  --ownership recommended \
  "${PKG_OUT}"

# Clean up staging dir; keep the pkg.
rm -rf build

echo
echo "Built: ${PKG_OUT}  ($(du -h "${PKG_OUT}" | cut -f1))"
echo
echo "Sharing:"
echo "  • Send ${PKG_OUT} to the recipient."
echo "  • The .pkg is NOT signed with an Apple Developer ID, so on macOS"
echo "    Gatekeeper will refuse to open it on a normal double-click."
echo "  • Recipient: right-click the .pkg → Open  (one-time per .pkg)."
echo "  • After install, the app is in /Applications/SSHManager.app."
echo "    First launch: right-click the .app → Open  (one-time per .app)."
echo "    Or, in Terminal:  xattr -dr com.apple.quarantine /Applications/SSHManager.app"
