#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/macos"
APP_NAME="ReadArc"
BASE_VERSION="${READARC_BASE_VERSION:-0.1.0}"
BUILD_NUMBER="${READARC_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 23)"
fi
if [[ "${GITHUB_REF_NAME:-}" == v* ]]; then
  BUILD_NAME="${READARC_BUILD_NAME:-${GITHUB_REF_NAME#v}}"
  VERSION="${READARC_VERSION:-$BUILD_NAME}"
else
  BUILD_NAME="${READARC_BUILD_NAME:-$BASE_VERSION}"
  VERSION="${READARC_VERSION:-$BASE_VERSION-snapshot.$BUILD_NUMBER}"
fi
BUILD_DEBUG_ARTIFACTS="${BUILD_DEBUG_ARTIFACTS:-false}"
REQUIRE_NATIVE_ENGINES="${READARC_REQUIRE_NATIVE_ENGINES:-false}"
DMG_NAME="ReadArc-${VERSION}-macos-release.dmg"
PKG_NAME="ReadArc-${VERSION}-macos-release.pkg"

export READARC_PLATFORMS="macos"
"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"

# Build the embedded DJVU engine when Rust is available. The library is copied
# into the .app bundle after Flutter produces the release app.
if ! "$ROOT_DIR/scripts/build_native_engines.sh" macos; then
  if [[ "$REQUIRE_NATIVE_ENGINES" == "true" ]]; then
    echo "ERROR: verified packages require the embedded universal macOS engine." >&2
    exit 1
  fi
  echo "Embedded DJVU macOS engine was not built. Continuing build without external converters." >&2
fi

build_with_optional_define() {
  local relay_define="${READARC_DEFAULT_RELAY_URL:-https://relay.readarc.ru}"
  local args=("$@")
  if [[ -n "$relay_define" ]]; then
    args+=(--dart-define="READARC_DEFAULT_RELAY_URL=$relay_define")
  fi
  flutter "${args[@]}"
}

echo "Building macOS release app..."
build_with_optional_define build macos --release --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER"

APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "Could not find built release .app bundle." >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGED_APP="$STAGE_ROOT/$APP_NAME.app"
cp -R "$APP_PATH" "$STAGED_APP"

DJVU_DYLIB="$ROOT_DIR/native/readarc_engines/dist/macos/libreadarc_djvu_engine.dylib"
if [[ -f "$DJVU_DYLIB" ]]; then
  mkdir -p "$STAGED_APP/Contents/Frameworks"
  cp "$DJVU_DYLIB" "$STAGED_APP/Contents/Frameworks/libreadarc_djvu_engine.dylib"
fi

# The native DJVU dylib is copied into the bundle after Flutter/Xcode finishes.
# Without re-signing the modified bundle, Gatekeeper can report that ReadArc.app
# is "damaged". Internal snapshot builds use ad-hoc signing; public builds
# should replace this with Developer ID signing + notarization.
if command -v codesign >/dev/null 2>&1; then
  xattr -cr "$STAGED_APP" 2>/dev/null || true
  if [[ -f "$STAGED_APP/Contents/Frameworks/libreadarc_djvu_engine.dylib" ]]; then
    codesign --force --sign - "$STAGED_APP/Contents/Frameworks/libreadarc_djvu_engine.dylib"
  fi
  # Re-sign only the modified outer bundle and explicitly restore its release
  # entitlements. A plain `codesign --deep --sign -` discards every
  # Xcode-produced entitlement. ReadArc intentionally uses the legacy encrypted
  # macOS Keychain until Developer ID signing is available, because the Data
  # Protection Keychain entitlement requires a provisioning profile.
  codesign \
    --force \
    --sign - \
    --entitlements "$APP_DIR/macos/Runner/Release.entitlements" \
    "$STAGED_APP"
  signed_entitlements="$(codesign -d --entitlements :- "$STAGED_APP" 2>/dev/null)"
  if ! grep -q '<key>com.apple.security.app-sandbox</key>' <<< "$signed_entitlements"; then
    echo "ERROR: packaged ReadArc.app lost its release entitlements." >&2
    exit 1
  fi
  if ! grep -q '<key>com.apple.security.files.bookmarks.app-scope</key>' <<< "$signed_entitlements"; then
    echo "ERROR: packaged ReadArc.app lost persistent security-scoped bookmark access." >&2
    exit 1
  fi
  if grep -q '<key>keychain-access-groups</key>' <<< "$signed_entitlements"; then
    echo "ERROR: ad-hoc ReadArc.app unexpectedly requires a Keychain Sharing provisioning profile." >&2
    exit 1
  fi
  codesign --verify --deep --strict "$STAGED_APP"
fi

# Plain release .app zip, useful for quick testing.
ditto -c -k --keepParent "$STAGED_APP" "$DIST_DIR/ReadArc-${VERSION}-macos-release-app.zip"

# Unsigned release PKG for local/internal testing. Public distribution should use Developer ID signing + notarization.
productbuild --component "$STAGED_APP" /Applications "$DIST_DIR/$PKG_NAME"

# Unsigned release DMG for local/internal testing.
DMG_ROOT="$STAGE_ROOT/dmg"
mkdir -p "$DMG_ROOT"
cp -R "$STAGED_APP" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME"

if [[ "$BUILD_DEBUG_ARTIFACTS" == "true" || "$BUILD_DEBUG_ARTIFACTS" == "1" ]]; then
  echo "Building optional macOS debug app zip..."
  build_with_optional_define build macos --debug --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER"
  DEBUG_APP_PATH="$(find build/macos/Build/Products/Debug -maxdepth 1 -name '*.app' -print -quit)"
  if [[ -n "${DEBUG_APP_PATH:-}" && -d "$DEBUG_APP_PATH" ]]; then
    DEBUG_STAGE="$STAGE_ROOT/${APP_NAME}-debug.app"
    cp -R "$DEBUG_APP_PATH" "$DEBUG_STAGE"
    ditto -c -k --keepParent "$DEBUG_STAGE" "$DIST_DIR/ReadArc-${VERSION}-macos-debug-app.zip"
  fi
fi

(
  cd "$DIST_DIR"
  shasum -a 256 * > SHA256SUMS
)

echo "macOS artifacts:"
ls -lh "$DIST_DIR"
echo
echo "macOS artifact sizes:"
du -h "$DIST_DIR"/* | sort -h
