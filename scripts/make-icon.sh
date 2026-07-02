#!/bin/bash
# Regenerate Resources/AppIcon.icns from app_icon.png (repo root).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> extracting subject from app_icon.png"
swift scripts/make-icon.swift

ICONSET="build/icon/AppIcon.iconset"
MASTER="build/icon/AppIcon-1024.png"

echo "==> building ${ICONSET}"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${MASTER}" \
        --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "${double}" "${double}" "${MASTER}" \
        --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> iconutil → Resources/AppIcon.icns"
iconutil -c icns "${ICONSET}" -o "Resources/AppIcon.icns"

echo "Done: Resources/AppIcon.icns"
