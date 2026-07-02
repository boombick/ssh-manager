#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="SSHManager.app"
EXEC=".build/${CONFIG}/SSHManager"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

if [[ ! -f "${EXEC}" ]]; then
    echo "Build did not produce ${EXEC}" >&2
    exit 1
fi

echo "==> packaging ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${EXEC}" "${APP}/Contents/MacOS/SSHManager"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so launchd / Gatekeeper are happy with a local build.
codesign --force --sign - "${APP}" >/dev/null 2>&1 || true

echo
echo "Built: ${APP}"
echo "Run:   open ./${APP}"
echo "Config will be created at: ~/Library/Application Support/SSHManager/config.json"
