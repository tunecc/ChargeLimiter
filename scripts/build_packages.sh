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
STAGE_DIR=""

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

force_clean_dir() {
  dir="$1"
  [ -e "$dir" ] || return 0

  attempts=0
  while [ "$attempts" -lt 5 ] && [ -e "$dir" ]; do
    rm -rf "$dir" 2>/dev/null || true
    if [ -e "$dir" ]; then
      # Handle transient ENOTEMPTY / permission edge cases on macOS.
      chmod -R u+w "$dir" 2>/dev/null || true
      find "$dir" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true
      rm -rf "$dir" 2>/dev/null || true
    fi
    attempts=$((attempts + 1))
    [ -e "$dir" ] && sleep 1 || true
  done

  if [ -e "$dir" ]; then
    echo "[ERR] Failed to clean directory: $dir" >&2
    exit 1
  fi
}

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

cleanup() {
  status=$?

  if [ -n "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi

  if [ -d "$PAYLOAD_DIR" ]; then
    rm -rf "$PAYLOAD_DIR"
  fi

  return "$status"
}

trap cleanup EXIT INT TERM

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
APP_ENT_TS="$ROOT_DIR/ChargeLimiter/ChargeLimiter.app.entitlements"
APP_ENT_JB="$ROOT_DIR/ChargeLimiter/ChargeLimiter.app.jb.entitlements"
DAEMON_ENT="$ROOT_DIR/ChargeLimiter/ChargeLimiter.entitlements"

TIPA_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_TrollStore.tipa"
ROOTLESS_DEB_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_rootless_arm64.deb"
ROOTHIDE_DEB_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_roothide_arm64e.deb"
TROLLSTORE_BANNED_ENTITLEMENTS_REGEX="com\\.apple\\.private\\.cs\\.debugger|dynamic-codesigning|com\\.apple\\.private\\.skip-library-validation"

force_clean_dir "$BUILD_ROOTLESS"
force_clean_dir "$BUILD_ROOTHIDE"
force_clean_dir "$PAYLOAD_DIR"
mkdir -p "$OUT_DIR" "$PAYLOAD_DIR"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chargelimiter-pack.XXXXXX")"
STAGE_ROOTLESS_DIR="$STAGE_DIR/rootless"
STAGE_ROOTHIDE_DIR="$STAGE_DIR/roothide"

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
  APP_ENT="$2"
  [ -f "$APP_PATH/ChargeLimiter" ] || { echo "[ERR] Missing binary: $APP_PATH/ChargeLimiter" >&2; exit 1; }
  [ -f "$APP_PATH/ChargeLimiterDaemon" ] || { echo "[ERR] Missing binary: $APP_PATH/ChargeLimiterDaemon" >&2; exit 1; }
  # Align with common TrollStore packaging flow: sign app bundle entry.
  ldid -S"$APP_ENT" "$APP_PATH"
  # Keep dedicated entitlements for each executable.
  ldid -S"$APP_ENT" "$APP_PATH/ChargeLimiter"
  ldid -S"$DAEMON_ENT" "$APP_PATH/ChargeLimiterDaemon"
  rm -rf "$APP_PATH/_CodeSignature"
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
sign_app "$ROOTLESS_APP" "$APP_ENT_JB"
sign_app "$ROOTHIDE_APP" "$APP_ENT_JB"

echo "[5/8] Prepare package trees..."
cp -a "$PKG_ROOTLESS_DIR" "$STAGE_ROOTLESS_DIR"
cp -a "$PKG_ROOTHIDE_DIR" "$STAGE_ROOTHIDE_DIR"
rm -rf "$STAGE_ROOTLESS_DIR/Applications" "$STAGE_ROOTHIDE_DIR/Applications"
rm -rf "$STAGE_ROOTLESS_DIR/var/jb/Applications/ChargeLimiter.app"
rm -rf "$STAGE_ROOTHIDE_DIR/var/jb/Applications/ChargeLimiter.app"
cp -a "$ROOTLESS_APP" "$STAGE_ROOTLESS_DIR/var/jb/Applications/ChargeLimiter.app"
cp -a "$ROOTHIDE_APP" "$STAGE_ROOTHIDE_DIR/var/jb/Applications/ChargeLimiter.app"

find "$STAGE_ROOTLESS_DIR" -name .DS_Store -delete
find "$STAGE_ROOTHIDE_DIR" -name .DS_Store -delete
chmod 755 "$STAGE_ROOTLESS_DIR/DEBIAN"/* "$STAGE_ROOTHIDE_DIR/DEBIAN"/*
set_control_version "$STAGE_ROOTLESS_DIR/DEBIAN/control"
set_control_version "$STAGE_ROOTHIDE_DIR/DEBIAN/control"

echo "[6/8] Build TrollStore package..."
cp -a "$ROOTLESS_APP" "$PAYLOAD_DIR/ChargeLimiter.app"
sign_app "$PAYLOAD_DIR/ChargeLimiter.app" "$APP_ENT_TS"
find "$PAYLOAD_DIR" -name .DS_Store -delete
(
  cd "$ROOT_DIR"
  rm -f "$TIPA_OUT"
  zip -r "$TIPA_OUT" Payload >/dev/null
)
rm -rf "$PAYLOAD_DIR"

echo "[7/8] Build deb packages..."
rm -f "$ROOTLESS_DEB_OUT" "$ROOTHIDE_DEB_OUT"
dpkg-deb -Zxz -b "$STAGE_ROOTLESS_DIR" "$ROOTLESS_DEB_OUT" >/dev/null
dpkg-deb -Zxz -b "$STAGE_ROOTHIDE_DIR" "$ROOTHIDE_DEB_OUT" >/dev/null

extract_arch() {
  xcrun lipo -info "$1" | sed -n 's/.*architecture: \(.*\)$/\1/p'
}

check_binary() {
  BIN_PATH="$1"
  EXPECTED_ARCH="$2"
  BUNDLE_ID="$3"

  [ -f "$BIN_PATH" ] || {
    echo "[ERR] Missing binary: $BIN_PATH" >&2
    exit 1
  }

  if ! ENT="$(ldid -e "$BIN_PATH" 2>/dev/null)"; then
    echo "[ERR] Failed to extract entitlements: $BIN_PATH" >&2
    exit 1
  fi

  echo "$ENT" | rg -F -q "<string>$BUNDLE_ID</string>" || {
    echo "[ERR] application-identifier mismatch in $BIN_PATH" >&2
    exit 1
  }

  echo "$ENT" | rg -q "$TROLLSTORE_BANNED_ENTITLEMENTS_REGEX" && {
    echo "[ERR] Found TrollStore banned entitlement in $BIN_PATH" >&2
    exit 1
  }

  ARCH="$(extract_arch "$BIN_PATH")"
  if [ "$ARCH" != "$EXPECTED_ARCH" ]; then
    echo "[ERR] Arch mismatch: expected $EXPECTED_ARCH, got $ARCH ($BIN_PATH)" >&2
    exit 1
  fi
}

check_app() {
  APP_PATH="$1"
  EXPECTED_ARCH="$2"

  BID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist")"
  if [ "$BID" != "com.chargelimiter.mod" ]; then
    echo "[ERR] Unexpected bundle id: $BID ($APP_PATH)" >&2
    exit 1
  fi

  check_binary "$APP_PATH/ChargeLimiter" "$EXPECTED_ARCH" "$BID"
  check_binary "$APP_PATH/ChargeLimiterDaemon" "$EXPECTED_ARCH" "$BID"
}

echo "[8/8] Verify package contents..."
check_app "$ROOTLESS_APP" "arm64"
check_app "$ROOTHIDE_APP" "arm64e"

echo "[OK] Done"
echo "[OUT] $TIPA_OUT"
echo "[OUT] $ROOTLESS_DEB_OUT"
echo "[OUT] $ROOTHIDE_DEB_OUT"
