#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/ChargeLimiter.xcodeproj"
OUT_DIR="$ROOT_DIR/out"
PKG_ROOTFUL_DIR="$ROOT_DIR/ChargeLimiter/Package"
PKG_ROOTLESS_DIR="$ROOT_DIR/ChargeLimiter/Package_rootless"
BUILD_ROOTFUL="$ROOT_DIR/build_rootful"
BUILD_ROOTLESS="$ROOT_DIR/build_rootless"
PAYLOAD_DIR="$ROOT_DIR/Payload"
ROOTHIDE_MERGE_ENT="$ROOT_DIR/scripts/roothide.entitlements"
STAGE_DIR=""
BUILD_LOG_ROOT=""
BUILD_LEGACY_ROOTHIDE="${CHARGELIMITER_BUILD_ROOTHIDE:-${CHARGELIMITER_BUILD_LEGACY_ROOTHIDE:-1}}"
DPKG_DEB_SUPPORTS_ROOT_OWNER_GROUP=0

usage() {
  cat >&2 <<EOF
Usage: $0 [VERSION] [--skip-roothide] [--legacy-roothide-convert]

Build TrollStore, rootful, rootless, and roothide packages into out/.

This repository still has no native roothide Xcode packaging entry, so the
default roothide package is produced by converting the rootless staging tree.
That output is installable for roothide users, but it is not the same as a
future native THEOS_PACKAGE_SCHEME=roothide release path.

Options:
  --skip-roothide            Do not build the roothide package.
  --legacy-roothide-convert  Compatibility alias. The current default already
                             builds the roothide package by conversion.
EOF
}

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
require_cmd rg

if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
  DPKG_DEB_SUPPORTS_ROOT_OWNER_GROUP=1
fi

run_logged_command() {
  log_name="$1"
  shift

  if [ -z "$BUILD_LOG_ROOT" ]; then
    BUILD_LOG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chargelimiter-build-logs.XXXXXX")"
  fi

  log_path="$BUILD_LOG_ROOT/${log_name}.log"
  if "$@" >"$log_path" 2>&1; then
    return 0
  fi

  status=$?
  echo "[ERR] Command failed: $*" >&2
  echo "[ERR] Build log: $log_path" >&2
  echo "[ERR] Last 200 log lines:" >&2
  tail -n 200 "$log_path" >&2 || true
  exit "$status"
}

dpkg_build_package() {
  stage_path="$1"
  out_path="$2"

  if [ "$DPKG_DEB_SUPPORTS_ROOT_OWNER_GROUP" = "1" ]; then
    dpkg-deb --root-owner-group -Zxz -b "$stage_path" "$out_path" >/dev/null
  else
    dpkg-deb -Zxz -b "$stage_path" "$out_path" >/dev/null
  fi
}

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

clean_host_metadata() {
  dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" \( -name .DS_Store -o -name __MACOSX -o -name '._*' \) -exec rm -rf {} + 2>/dev/null || true
}

clean_known_outputs() {
  [ -d "$OUT_DIR" ] || return 0
  find "$OUT_DIR" -maxdepth 1 -type f -name 'ChargeLimiter_*' -delete
}

require_project_build_environment() {
  missing=0
  for header in \
    IOKit/hid/IOHIDService.h \
    MobileCoreServices/LSApplicationProxy.h
  do
    found=0
    for include_root in /opt/theos/vendor/include /opt/include; do
      if [ -f "$include_root/$header" ]; then
        found=1
        break
      fi
    done

    if [ "$found" -ne 1 ]; then
      echo "[ERR] Missing build dependency header: $header" >&2
      missing=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    echo "[ERR] Prepare Theos headers before building. This project searches /opt/theos/vendor/include and /opt/include." >&2
    echo "[ERR] Example: clone Theos to /opt/theos; /opt/include may also point to /opt/theos/vendor/include." >&2
    exit 1
  fi
}

copy_tree_contents() {
  src_dir="$1"
  dst_dir="$2"
  [ -d "$src_dir" ] || return 0
  mkdir -p "$dst_dir"
  cp -a "$src_dir"/. "$dst_dir"/
}

require_legacy_roothide_enabled() {
  if [ "$BUILD_LEGACY_ROOTHIDE" != "1" ]; then
    echo "[ERR] Legacy roothide conversion called without CHARGELIMITER_BUILD_LEGACY_ROOTHIDE=1." >&2
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

set_roothide_control_arch() {
  control_file="$1"
  tmp_file="${control_file}.tmp.$$"
  awk '
    BEGIN { done = 0 }
    /^Architecture:[[:space:]]*/ { print "Architecture: iphoneos-arm64e"; done = 1; next }
    NF { print }
    END { if (!done) print "Architecture: iphoneos-arm64e" }
  ' "$control_file" > "$tmp_file"
  mv "$tmp_file" "$control_file"
}

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

copy_rootless_stage_to_roothide_layout() {
  require_legacy_roothide_enabled

  src_stage="$1"
  dst_stage="$2"

  rm -rf "$dst_stage"
  mkdir -p "$dst_stage"

  cp -a "$src_stage/DEBIAN" "$dst_stage/DEBIAN"

  if [ -d "$src_stage/var/jb" ]; then
    copy_tree_contents "$src_stage/var/jb" "$dst_stage"
  fi

  find "$src_stage" -mindepth 1 -maxdepth 1 | while IFS= read -r entry; do
    base_name="$(basename "$entry")"
    case "$base_name" in
      DEBIAN)
        ;;
      var)
        if [ -d "$entry" ]; then
          find "$entry" -mindepth 1 -maxdepth 1 | while IFS= read -r var_entry; do
            [ "$(basename "$var_entry")" = "jb" ] && continue
            mkdir -p "$dst_stage/rootfs/var"
            cp -a "$var_entry" "$dst_stage/rootfs/var/"
          done
        else
          mkdir -p "$dst_stage/rootfs"
          cp -a "$entry" "$dst_stage/rootfs/"
        fi
        ;;
      *)
        mkdir -p "$dst_stage/rootfs"
        cp -a "$entry" "$dst_stage/rootfs/"
        ;;
    esac
  done
}

list_rpaths() {
  xcrun otool -l "$1" |
  awk '
    /^[^ ]/ { in_rpath = 0 }
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

change_macho_rpath() {
  target_file="$1"
  old_path="$2"
  new_path="$3"
  if ! xcrun install_name_tool -rpath "$old_path" "$new_path" "$target_file"; then
    ldid -s "$target_file"
    xcrun install_name_tool -rpath "$old_path" "$new_path" "$target_file"
  fi
}

change_macho_load_path() {
  target_file="$1"
  old_path="$2"
  new_path="$3"
  if ! xcrun install_name_tool -change "$old_path" "$new_path" "$target_file"; then
    ldid -s "$target_file"
    xcrun install_name_tool -change "$old_path" "$new_path" "$target_file"
  fi
}

rewrite_macho_for_roothide() {
  require_legacy_roothide_enabled

  target_file="$1"

  list_rpaths "$target_file" | while IFS= read -r rpath; do
    case "$rpath" in
      /var/jb/*)
        new_rpath="$(printf '%s\n' "$rpath" | sed 's|^/var/jb/|@loader_path/.jbroot/|')"
        change_macho_rpath "$target_file" "$rpath" "$new_rpath"
        ;;
    esac
  done

  xcrun otool -L "$target_file" | awk 'NR > 1 { print $1 }' | while IFS= read -r dep; do
    case "$dep" in
      /var/jb/*)
        new_dep="$(printf '%s\n' "$dep" | sed 's|^/var/jb/|@loader_path/.jbroot/|')"
        change_macho_load_path "$target_file" "$dep" "$new_dep"
        ;;
    esac
  done

  file_type="$(file -b "$target_file")"
  if printf '%s\n' "$file_type" | grep -q "executable"; then
    # Match RootHidePatcher behavior: merge roothide-specific runtime entitlements
    # into the executable's existing entitlement set instead of replacing it.
    ldid -M "-S$ROOTHIDE_MERGE_ENT" "$target_file"
  else
    ldid -S "$target_file"
  fi
}

rewrite_roothide_maintainer_script() {
  require_legacy_roothide_enabled

  target_file="$1"
  tmp_file="${target_file}.tmp.$$"
  sed \
    -e 's|iphoneos-arm64|iphoneos-arm64e|g' \
    -e 's|/var/jb/|/-var/jb/-|g' \
    -e 's|/var/jb|/-var/jb-|g' \
    -e 's| /Applications/| /rootfs/Applications/|g' \
    -e 's| /Library/| /rootfs/Library/|g' \
    -e 's| /private/| /rootfs/private/|g' \
    -e 's| /System/| /rootfs/System/|g' \
    -e 's| /sbin/| /rootfs/sbin/|g' \
    -e 's| /bin/| /rootfs/bin/|g' \
    -e 's| /etc/| /rootfs/etc/|g' \
    -e 's| /lib/| /rootfs/lib/|g' \
    -e 's| /usr/| /rootfs/usr/|g' \
    -e 's| /var/| /rootfs/var/|g' \
    -e 's|DIR="/Library/|DIR="/rootfs/Library/|g' \
    -e 's|/rootfs/usr/bin/jbroot|/usr/bin/jbroot|g' \
    -e 's|/rootfs/var/mobile/Library/Preferences|/var/mobile/Library/Preferences|g' \
    -e '1s|^#![[:space:]]*/rootfs/|#! /|' \
    -e 's|/-var/jb/-|/|g' \
    -e 's|/-var/jb-|/var/jb|g' \
    "$target_file" > "$tmp_file"
  mv "$tmp_file" "$target_file"
  chmod 755 "$target_file"
}

rewrite_roothide_launchdaemon_plist() {
  require_legacy_roothide_enabled

  target_file="$1"
  tmp_file="${target_file}.tmp.$$"
  plutil -convert xml1 "$target_file" >/dev/null 2>&1 || true
  sed 's|/var/jb/|/|g' "$target_file" > "$tmp_file"
  mv "$tmp_file" "$target_file"
}

convert_rootless_stage_to_roothide() {
  require_legacy_roothide_enabled

  src_stage="$1"
  dst_stage="$2"

  copy_rootless_stage_to_roothide_layout "$src_stage" "$dst_stage"

  find "$dst_stage" -type f | while IFS= read -r file_path; do
    case "$(basename "$file_path")" in
      preinst|prerm|postinst|postrm|extrainst_*)
        rewrite_roothide_maintainer_script "$file_path"
        ;;
    esac

    case "$file_path" in
      */Library/LaunchDaemons/*.plist)
        rewrite_roothide_launchdaemon_plist "$file_path"
        ;;
    esac

    if file -b "$file_path" | grep -q "Mach-O"; then
      rewrite_macho_for_roothide "$file_path"
    fi
  done

  clean_host_metadata "$dst_stage"
  chmod 755 "$dst_stage/DEBIAN"/*
  set_roothide_control_arch "$dst_stage/DEBIAN/control"
}

cleanup() {
  status=$?

  if [ -n "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi

  if [ -d "$PAYLOAD_DIR" ]; then
    rm -rf "$PAYLOAD_DIR"
  fi

  if [ -n "$BUILD_LOG_ROOT" ] && [ -d "$BUILD_LOG_ROOT" ]; then
    rm -rf "$BUILD_LOG_ROOT"
  fi

  return "$status"
}

trap cleanup EXIT INT TERM

VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-roothide)
      BUILD_LEGACY_ROOTHIDE=0
      ;;
    --legacy-roothide-convert)
      BUILD_LEGACY_ROOTHIDE=1
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "[ERR] Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "$VERSION" ]; then
        echo "[ERR] Version was provided more than once." >&2
        usage
        exit 1
      fi
      VERSION="$1"
      ;;
  esac
  shift
done

case "$BUILD_LEGACY_ROOTHIDE" in
  0|1)
    ;;
  *)
    echo "[ERR] CHARGELIMITER_BUILD_ROOTHIDE / CHARGELIMITER_BUILD_LEGACY_ROOTHIDE must be 0 or 1." >&2
    exit 1
    ;;
esac

if [ "$BUILD_LEGACY_ROOTHIDE" = "1" ]; then
  require_cmd file
  [ -f "$ROOTHIDE_MERGE_ENT" ] || {
    echo "[ERR] Missing roothide compatibility entitlements: $ROOTHIDE_MERGE_ENT" >&2
    exit 1
  }
fi

if [ -z "$VERSION" ]; then
    VERSION="$(awk -F' = ' '/MARKETING_VERSION =/{gsub(/;/, "", $2); print $2; exit}' "$ROOT_DIR/ChargeLimiter.xcodeproj/project.pbxproj")"
fi

if [ -z "$VERSION" ]; then
    echo "[ERR] Unable to resolve version." >&2
    exit 1
fi

ROOTFUL_APP="$BUILD_ROOTFUL/Build/Products/Release-iphoneos/ChargeLimiter.app"
ROOTLESS_APP="$BUILD_ROOTLESS/Build/Products/Release-iphoneos/ChargeLimiter.app"
APP_ENT_TS="$ROOT_DIR/ChargeLimiter/ChargeLimiter.app.entitlements"
APP_ENT_JB="$ROOT_DIR/ChargeLimiter/ChargeLimiter.app.jb.entitlements"
DAEMON_ENT="$ROOT_DIR/ChargeLimiter/ChargeLimiter.entitlements"

TIPA_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_TrollStore.tipa"
ROOTFUL_DEB_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_rootful_arm.deb"
ROOTLESS_DEB_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_rootless_arm64.deb"
ROOTHIDE_DEB_OUT="$OUT_DIR/ChargeLimiter_${VERSION}_roothide_arm64e.deb"
TROLLSTORE_BANNED_ENTITLEMENTS_REGEX="com\\.apple\\.private\\.cs\\.debugger|dynamic-codesigning|com\\.apple\\.private\\.skip-library-validation"

force_clean_dir "$BUILD_ROOTFUL"
force_clean_dir "$BUILD_ROOTLESS"
force_clean_dir "$PAYLOAD_DIR"
require_project_build_environment
mkdir -p "$OUT_DIR" "$PAYLOAD_DIR"
clean_known_outputs
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chargelimiter-pack.XXXXXX")"
STAGE_ROOTFUL_DIR="$STAGE_DIR/rootful"
STAGE_ROOTLESS_DIR="$STAGE_DIR/rootless"
STAGE_ROOTHIDE_DIR="$STAGE_DIR/roothide"

if [ "$BUILD_LEGACY_ROOTHIDE" = "1" ]; then
  echo "[WARN] roothide package will be built by converting the rootless staging tree because this project still has no native roothide Xcode packaging entry."
fi

echo "[1/9] Build rootful app (arm64)..."
run_logged_command build-rootful xcodebuild \
  -project "$PROJECT" \
  -scheme "ChargeLimiter" \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -derivedDataPath "$BUILD_ROOTFUL" \
  CODE_SIGNING_ALLOWED=NO \
  THEOS_PACKAGE_SCHEME= \
  THEOS_PACKAGE_INSTALL_PREFIX= \
  ARCHS=arm64 \
  MonkeyDevInstallOnAnyBuild=NO \
  MonkeyDevBuildPackageOnAnyBuild=NO

echo "[2/9] Build rootless app (arm64)..."
run_logged_command build-rootless xcodebuild \
  -project "$PROJECT" \
  -scheme "ChargeLimiter rootless" \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -derivedDataPath "$BUILD_ROOTLESS" \
  CODE_SIGNING_ALLOWED=NO \
  THEOS_PACKAGE_SCHEME=rootless \
  THEOS_PACKAGE_INSTALL_PREFIX=/var/jb \
  ARCHS=arm64 \
  MonkeyDevInstallOnAnyBuild=NO \
  MonkeyDevBuildPackageOnAnyBuild=NO

if [ ! -d "$ROOTFUL_APP" ] || [ ! -d "$ROOTLESS_APP" ]; then
    echo "[ERR] Build output app not found." >&2
    exit 1
fi

echo "[3/9] Strip app binaries..."
strip_app "$ROOTFUL_APP"
strip_app "$ROOTLESS_APP"

echo "[4/9] Sign app binaries..."
sign_app "$ROOTFUL_APP" "$APP_ENT_JB"
sign_app "$ROOTLESS_APP" "$APP_ENT_JB"

echo "[5/9] Prepare package trees..."
cp -a "$PKG_ROOTFUL_DIR" "$STAGE_ROOTFUL_DIR"
cp -a "$PKG_ROOTLESS_DIR" "$STAGE_ROOTLESS_DIR"
[ -d "$STAGE_ROOTFUL_DIR/DEBIAN" ] || {
  echo "[ERR] Missing rootful package template: $STAGE_ROOTFUL_DIR/DEBIAN" >&2
  exit 1
}
[ -d "$STAGE_ROOTLESS_DIR/DEBIAN" ] || {
  echo "[ERR] Missing rootless package template: $STAGE_ROOTLESS_DIR/DEBIAN" >&2
  exit 1
}
rm -rf "$STAGE_ROOTFUL_DIR/Applications/ChargeLimiter.app"
rm -rf "$STAGE_ROOTLESS_DIR/Applications"
rm -rf "$STAGE_ROOTLESS_DIR/var/jb/Applications/ChargeLimiter.app"
mkdir -p "$STAGE_ROOTFUL_DIR/Applications"
mkdir -p "$STAGE_ROOTLESS_DIR/var/jb/Applications"
cp -a "$ROOTFUL_APP" "$STAGE_ROOTFUL_DIR/Applications/ChargeLimiter.app"
cp -a "$ROOTLESS_APP" "$STAGE_ROOTLESS_DIR/var/jb/Applications/ChargeLimiter.app"

clean_host_metadata "$STAGE_ROOTFUL_DIR"
clean_host_metadata "$STAGE_ROOTLESS_DIR"
chmod 755 "$STAGE_ROOTFUL_DIR/DEBIAN"/* "$STAGE_ROOTLESS_DIR/DEBIAN"/*
set_control_version "$STAGE_ROOTFUL_DIR/DEBIAN/control"
set_control_version "$STAGE_ROOTLESS_DIR/DEBIAN/control"

if [ "$BUILD_LEGACY_ROOTHIDE" = "1" ]; then
  echo "[6/9] Convert rootless package tree to roothide layout..."
  convert_rootless_stage_to_roothide "$STAGE_ROOTLESS_DIR" "$STAGE_ROOTHIDE_DIR"
else
  echo "[6/9] Skip roothide package by request."
fi

echo "[7/9] Build TrollStore package..."
cp -a "$ROOTLESS_APP" "$PAYLOAD_DIR/ChargeLimiter.app"
sign_app "$PAYLOAD_DIR/ChargeLimiter.app" "$APP_ENT_TS"
clean_host_metadata "$PAYLOAD_DIR"
(
  cd "$ROOT_DIR"
  rm -f "$TIPA_OUT"
  zip -r "$TIPA_OUT" Payload >/dev/null
)
rm -rf "$PAYLOAD_DIR"

echo "[8/9] Build deb packages..."
rm -f "$ROOTFUL_DEB_OUT" "$ROOTLESS_DEB_OUT" "$ROOTHIDE_DEB_OUT"
dpkg_build_package "$STAGE_ROOTFUL_DIR" "$ROOTFUL_DEB_OUT"
dpkg_build_package "$STAGE_ROOTLESS_DIR" "$ROOTLESS_DEB_OUT"
if [ "$BUILD_LEGACY_ROOTHIDE" = "1" ]; then
  dpkg_build_package "$STAGE_ROOTHIDE_DIR" "$ROOTHIDE_DEB_OUT"
fi

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

check_deb_field() {
  deb_path="$1"
  field="$2"
  expected="$3"

  actual="$(dpkg-deb -f "$deb_path" "$field")"
  if [ "$actual" != "$expected" ]; then
    echo "[ERR] Unexpected $field in $deb_path: expected $expected, got $actual" >&2
    exit 1
  fi
}

check_no_host_metadata() {
  stage_path="$1"
  if find "$stage_path" \( -name .DS_Store -o -name __MACOSX -o -name '._*' \) | rg -q .; then
    echo "[ERR] Host metadata found in package stage: $stage_path" >&2
    find "$stage_path" \( -name .DS_Store -o -name __MACOSX -o -name '._*' \) >&2
    exit 1
  fi
}

check_deb_metadata() {
  deb_path="$1"
  expected_arch="$2"

  [ -f "$deb_path" ] || {
    echo "[ERR] Missing package output: $deb_path" >&2
    exit 1
  }

  check_deb_field "$deb_path" Package "com.chargelimiter.mod"
  check_deb_field "$deb_path" Version "$VERSION"
  check_deb_field "$deb_path" Architecture "$expected_arch"
}

check_rootful_stage() {
  stage_path="$1"
  app_path="$stage_path/Applications/ChargeLimiter.app"
  plist_path="$stage_path/Library/LaunchDaemons/com.chargelimiter.mod.plist"

  [ -d "$app_path" ] || {
    echo "[ERR] Missing rootful app bundle: $app_path" >&2
    exit 1
  }
  [ -f "$plist_path" ] || {
    echo "[ERR] Missing rootful launch daemon plist: $plist_path" >&2
    exit 1
  }
  [ ! -e "$stage_path/var/jb" ] || {
    echo "[ERR] Rootful package stage contains rootless install root: $stage_path/var/jb" >&2
    exit 1
  }
  check_no_host_metadata "$stage_path"
  check_app "$app_path" "arm64"
}

check_rootless_stage() {
  stage_path="$1"
  app_path="$stage_path/var/jb/Applications/ChargeLimiter.app"
  plist_path="$stage_path/var/jb/Library/LaunchDaemons/com.chargelimiter.mod.plist"

  [ -d "$app_path" ] || {
    echo "[ERR] Missing rootless app bundle: $app_path" >&2
    exit 1
  }
  [ -f "$plist_path" ] || {
    echo "[ERR] Missing rootless launch daemon plist: $plist_path" >&2
    exit 1
  }
  [ ! -e "$stage_path/Applications/ChargeLimiter.app" ] || {
    echo "[ERR] Rootless package stage contains rootful app path." >&2
    exit 1
  }
  check_no_host_metadata "$stage_path"
  check_app "$app_path" "arm64"
}

check_roothide_stage() {
  STAGE_PATH="$1"
  APP_PATH="$STAGE_PATH/Applications/ChargeLimiter.app"
  PLIST_PATH="$STAGE_PATH/Library/LaunchDaemons/com.chargelimiter.mod.plist"
  POSTINST_PATH="$STAGE_PATH/DEBIAN/postinst"
  PRERM_PATH="$STAGE_PATH/DEBIAN/prerm"
  POSTRM_PATH="$STAGE_PATH/DEBIAN/postrm"

  [ -d "$APP_PATH" ] || {
    echo "[ERR] Missing roothide app bundle: $APP_PATH" >&2
    exit 1
  }

  [ -f "$PLIST_PATH" ] || {
    echo "[ERR] Missing roothide launch daemon plist: $PLIST_PATH" >&2
    exit 1
  }

  [ ! -e "$STAGE_PATH/var/jb/Applications/ChargeLimiter.app" ] || {
    echo "[ERR] Found unexpected rootless app path in roothide stage." >&2
    exit 1
  }

  CONTROL_ARCH="$(awk -F': ' '/^Architecture:/{print $2; exit}' "$STAGE_PATH/DEBIAN/control")"
  if [ "$CONTROL_ARCH" != "iphoneos-arm64e" ]; then
    echo "[ERR] Unexpected roothide control architecture: $CONTROL_ARCH" >&2
    exit 1
  fi

  PLIST_PROGRAM="$(plutil -extract Program raw -o - "$PLIST_PATH")"
  if [ "$PLIST_PROGRAM" != "/Applications/ChargeLimiter.app/ChargeLimiterDaemon" ]; then
    echo "[ERR] Unexpected roothide launch daemon program path: $PLIST_PROGRAM" >&2
    exit 1
  fi

  rg -F -q 'APP_DIR="/Applications/ChargeLimiter.app"' "$POSTINST_PATH" || {
    echo "[ERR] roothide postinst APP_DIR was not rewritten." >&2
    exit 1
  }

  rg -F -q 'DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"' "$POSTINST_PATH" || {
    echo "[ERR] roothide postinst DAEMON_PLIST was not rewritten." >&2
    exit 1
  }

  rg -F -q 'APP_DIR="/Applications/ChargeLimiter.app"' "$PRERM_PATH" || {
    echo "[ERR] roothide prerm APP_DIR was not rewritten." >&2
    exit 1
  }

  rg -F -q 'DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"' "$PRERM_PATH" || {
    echo "[ERR] roothide prerm DAEMON_PLIST was not rewritten." >&2
    exit 1
  }

  rg -F -q 'APP_DIR="/Applications/ChargeLimiter.app"' "$POSTRM_PATH" || {
    echo "[ERR] roothide postrm APP_DIR was not rewritten." >&2
    exit 1
  }

  for script_path in "$POSTINST_PATH" "$PRERM_PATH" "$POSTRM_PATH"; do
    rg -F -q '/-var/jb' "$script_path" && {
      echo "[ERR] roothide maintainer script still contains conversion placeholder: $script_path" >&2
      exit 1
    }
    rg -F -q '/var/jb/Applications/ChargeLimiter.app' "$script_path" && {
      echo "[ERR] roothide maintainer script still contains rootless app path: $script_path" >&2
      exit 1
    }
    rg -F -q '/var/jb/Library/LaunchDaemons/com.chargelimiter.mod.plist' "$script_path" && {
      echo "[ERR] roothide maintainer script still contains rootless launch daemon path: $script_path" >&2
      exit 1
    }
    rg -F -q '/rootfs/usr/bin/jbroot' "$script_path" && {
      echo "[ERR] roothide maintainer script rewrote jbroot tool path through rootfs: $script_path" >&2
      exit 1
    }
    rg -F -q '/rootfs/var/mobile/Library/Preferences' "$script_path" && {
      echo "[ERR] roothide maintainer script passed a rootfs path to jbroot: $script_path" >&2
      exit 1
    }
  done

  # RootHidePatcher standard conversion keeps the rootless Mach-O slices and
  # rewrites the package/runtime layout around them instead of rebuilding arm64e.
  check_app "$APP_PATH" "arm64"
}

echo "[9/9] Verify package contents..."
check_rootful_stage "$STAGE_ROOTFUL_DIR"
check_rootless_stage "$STAGE_ROOTLESS_DIR"
check_deb_metadata "$ROOTFUL_DEB_OUT" "iphoneos-arm"
check_deb_metadata "$ROOTLESS_DEB_OUT" "iphoneos-arm64"
if [ "$BUILD_LEGACY_ROOTHIDE" = "1" ]; then
  check_roothide_stage "$STAGE_ROOTHIDE_DIR"
  check_no_host_metadata "$STAGE_ROOTHIDE_DIR"
  check_deb_metadata "$ROOTHIDE_DEB_OUT" "iphoneos-arm64e"
fi

echo "[OK] Done"
echo "[OUT] $TIPA_OUT"
echo "[OUT] $ROOTFUL_DEB_OUT"
echo "[OUT] $ROOTLESS_DEB_OUT"
if [ "$BUILD_LEGACY_ROOTHIDE" = "1" ]; then
  echo "[OUT] $ROOTHIDE_DEB_OUT"
  echo "[INFO] roothide package was built by compatibility conversion from the rootless staging tree. A true native roothide release path still needs a dedicated roothide packaging entry."
else
  echo "[INFO] roothide package was skipped."
fi
