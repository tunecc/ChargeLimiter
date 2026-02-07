#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/ChargeLimiter.xcodeproj"
OUT_DIR="$ROOT_DIR/out"
PKG_ROOTLESS_DIR="$ROOT_DIR/ChargeLimiter/Package_rootless"
PKG_ROOTHIDE_DIR="$ROOT_DIR/ChargeLimiter/Package_roothide"
BUILD_ROOTLESS="$ROOT_DIR/build_rootless"
BUILD_ROOTHIDE="$ROOT_DIR/build_roothide"
PAYLOAD_DIR="$ROOT_DIR/Payload"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[ERR] Missing command: $1" >&2
        exit 1
    }
}

require_cmd xcodebuild
require_cmd dpkg-deb
require_cmd zip
require_cmd ldid
require_cmd plutil
require_cmd xcrun
require_cmd ar
require_cmd tar
require_cmd rg

set_control_version() {
  control_file="$1"
  tmp_file="${control_file}.tmp.$$"
  awk -v ver="$VERSION" '
    BEGIN { done = 0 }
    /^Version:[[:space:]]*/ { print "Version: " ver; done = 1; next }
    { print }
    END { if (!done) print "Version: " ver }
  ' "$control_file" > "$tmp_file"
  mv "$tmp_file" "$control_file"
}

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(awk -F' = ' '/MARKETING_VERSION =/{gsub(/;/, "", $2); print $2; exit}' "$ROOT_DIR/ChargeLimiter.xcodeproj/project.pbxproj")"
fi

if [ -z "$VERSION" ]; then
    echo "[ERR] Unable to resolve version." >&2
    exit 1
fi

ROOTLESS_APP="$BUILD_ROOTLESS/Build/Products/Release-iphoneos/ChargeLimiter.app"
ROOTHIDE_APP="$BUILD_ROOTHIDE/Build/Products/Release-iphoneos/ChargeLimiter.app"
APP_ENT="$ROOT_DIR/ChargeLimiter/ChargeLimiter.app.entitlements"
DAEMON_ENT="$ROOT_DIR/ChargeLimiter/ChargeLimiter.entitlements"

TIPA_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_TrollStore.tipa"
ROOTLESS_DEB_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_rootless_arm64.deb"
ROOTHIDE_DEB_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_roothide_arm64e.deb"

rm -rf "$BUILD_ROOTLESS" "$BUILD_ROOTHIDE" "$PAYLOAD_DIR"
mkdir -p "$OUT_DIR" "$PAYLOAD_DIR"

echo "[1/8] Build rootless app (arm64)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "ChargeLimiter rootless" \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -derivedDataPath "$BUILD_ROOTLESS" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  MonkeyDevInstallOnAnyBuild=NO \
  MonkeyDevBuildPackageOnAnyBuild=NO >/dev/null

echo "[2/8] Build roothide app (arm64e)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "ChargeLimiter roothide" \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -derivedDataPath "$BUILD_ROOTHIDE" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64e \
  MonkeyDevInstallOnAnyBuild=NO \
  MonkeyDevBuildPackageOnAnyBuild=NO >/dev/null

if [ ! -d "$ROOTLESS_APP" ] || [ ! -d "$ROOTHIDE_APP" ]; then
    echo "[ERR] Build output app not found." >&2
    exit 1
fi

sign_app() {
  APP_PATH="$1"
  [ -f "$APP_PATH/ChargeLimiter" ] || { echo "[ERR] Missing binary: $APP_PATH/ChargeLimiter" >&2; exit 1; }
  [ -f "$APP_PATH/ChargeLimiterDaemon" ] || { echo "[ERR] Missing binary: $APP_PATH/ChargeLimiterDaemon" >&2; exit 1; }
  ldid -S"$APP_ENT" "$APP_PATH/ChargeLimiter"
  ldid -S"$DAEMON_ENT" "$APP_PATH/ChargeLimiterDaemon"
}

strip_app() {
  APP_PATH="$1"
  xcrun strip -S -x "$APP_PATH/ChargeLimiter"
  xcrun strip -S -x "$APP_PATH/ChargeLimiterDaemon"
}

echo "[3/8] Strip app binaries..."
strip_app "$ROOTLESS_APP"
strip_app "$ROOTHIDE_APP"

echo "[4/8] Sign app binaries..."
sign_app "$ROOTLESS_APP"
sign_app "$ROOTHIDE_APP"

echo "[5/8] Prepare package trees..."
rm -rf "$PKG_ROOTLESS_DIR/Applications" "$PKG_ROOTHIDE_DIR/Applications"
rm -rf "$PKG_ROOTLESS_DIR/var/jb/Applications/ChargeLimiter.app"
rm -rf "$PKG_ROOTHIDE_DIR/var/jb/Applications/ChargeLimiter.app"
cp -a "$ROOTLESS_APP" "$PKG_ROOTLESS_DIR/var/jb/Applications/ChargeLimiter.app"
cp -a "$ROOTHIDE_APP" "$PKG_ROOTHIDE_DIR/var/jb/Applications/ChargeLimiter.app"

find "$PKG_ROOTLESS_DIR" -name .DS_Store -delete
find "$PKG_ROOTHIDE_DIR" -name .DS_Store -delete
chmod 755 "$PKG_ROOTLESS_DIR/DEBIAN"/* "$PKG_ROOTHIDE_DIR/DEBIAN"/*
set_control_version "$PKG_ROOTLESS_DIR/DEBIAN/control"
set_control_version "$PKG_ROOTHIDE_DIR/DEBIAN/control"

echo "[6/8] Build TrollStore package..."
cp -a "$ROOTLESS_APP" "$PAYLOAD_DIR/ChargeLimiter.app"
find "$PAYLOAD_DIR" -name .DS_Store -delete
(
  cd "$ROOT_DIR"
  rm -f "$TIPA_OUT"
  zip -r "$TIPA_OUT" Payload >/dev/null
)
rm -rf "$PAYLOAD_DIR"

echo "[7/8] Build deb packages..."
rm -f "$ROOTLESS_DEB_OUT" "$ROOTHIDE_DEB_OUT"
dpkg-deb -Zxz -b "$PKG_ROOTLESS_DIR" "$ROOTLESS_DEB_OUT" >/dev/null
dpkg-deb -Zxz -b "$PKG_ROOTHIDE_DIR" "$ROOTHIDE_DEB_OUT" >/dev/null

extract_arch() {
  xcrun lipo -info "$1" | sed -n 's/.*architecture: \(.*\)$/\1/p'
}

check_app() {
  APP_PATH="$1"
  EXPECTED_ARCH="$2"

  BID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist")"
  if [ "$BID" != "com.chargelimiter.mod" ]; then
    echo "[ERR] Unexpected bundle id: $BID ($APP_PATH)" >&2
    exit 1
  fi

  ENT="$(ldid -e "$APP_PATH/ChargeLimiter")"
  echo "$ENT" | rg -q "<string>com\.chargelimiter\.mod</string>" || {
    echo "[ERR] application-identifier missing in $APP_PATH" >&2
    exit 1
  }
  echo "$ENT" | rg -q "no-container|no-sandbox" && {
    echo "[ERR] Found forbidden entitlement (no-container/no-sandbox) in $APP_PATH" >&2
    exit 1
  }

  ARCH="$(extract_arch "$APP_PATH/ChargeLimiter")"
  if [ "$ARCH" != "$EXPECTED_ARCH" ]; then
    echo "[ERR] Arch mismatch: expected $EXPECTED_ARCH, got $ARCH ($APP_PATH)" >&2
    exit 1
  fi
}

echo "[8/8] Verify package contents..."
check_app "$ROOTLESS_APP" "arm64"
check_app "$ROOTHIDE_APP" "arm64e"

echo "[OK] Done"
echo "[OUT] $TIPA_OUT"
echo "[OUT] $ROOTLESS_DEB_OUT"
echo "[OUT] $ROOTHIDE_DEB_OUT"
