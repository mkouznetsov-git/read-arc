#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/macos"
APP_NAME="ReadArc"
BASE_VERSION="${READARC_BASE_VERSION:-0.49.1}"
BUILD_NUMBER="${READARC_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 23)"
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ || "$BUILD_NUMBER" == "0" ]]; then
  echo "ERROR: macOS CFBundleVersion must be a positive integer, got: $BUILD_NUMBER" >&2
  exit 1
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
SIGNING_IDENTITY="${READARC_MACOS_SIGNING_IDENTITY:--}"
REQUIRE_STABLE_SIGNING="${READARC_REQUIRE_STABLE_MACOS_SIGNING:-false}"
DMG_NAME="ReadArc-${VERSION}-macos-release.dmg"
PKG_NAME="ReadArc-${VERSION}-macos-release.pkg"

if [[ "$REQUIRE_STABLE_SIGNING" == "true" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "ERROR: production macOS packages require a stable Developer ID signing identity." >&2
  exit 1
fi

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
  args+=(--dart-define="READARC_BUILD_NAME=$BUILD_NAME")
  args+=(--dart-define="READARC_BUILD_NUMBER=$BUILD_NUMBER")
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

INFO_PLIST="$STAGED_APP/Contents/Info.plist"
ACTUAL_BUILD_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
ACTUAL_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ "$ACTUAL_BUILD_NAME" != "$BUILD_NAME" || "$ACTUAL_BUILD_NUMBER" != "$BUILD_NUMBER" ]]; then
  echo "ERROR: packaged macOS version mismatch: expected=$BUILD_NAME ($BUILD_NUMBER) actual=$ACTUAL_BUILD_NAME ($ACTUAL_BUILD_NUMBER)" >&2
  exit 1
fi
{
  echo "CFBundleShortVersionString=$ACTUAL_BUILD_NAME"
  echo "CFBundleVersion=$ACTUAL_BUILD_NUMBER"
  echo "displayBuild=$BUILD_NAME ($BUILD_NUMBER)"
} > "$DIST_DIR/MACOS_BUILD_METADATA.txt"

DJVU_DYLIB="$ROOT_DIR/native/readarc_engines/dist/macos/libreadarc_djvu_engine.dylib"
if [[ -f "$DJVU_DYLIB" ]]; then
  mkdir -p "$STAGED_APP/Contents/Frameworks"
  cp "$DJVU_DYLIB" "$STAGED_APP/Contents/Frameworks/libreadarc_djvu_engine.dylib"
fi

# The native DJVU dylib is copied into the bundle after Flutter/Xcode finishes.
# Without re-signing the modified bundle, Gatekeeper can report that ReadArc.app
# is "damaged". Internal snapshot builds use explicitly documented ad-hoc
# signing; production packaging fails closed unless a stable Developer ID is
# provided by protected CI configuration.
if command -v codesign >/dev/null 2>&1; then
  xattr -cr "$STAGED_APP" 2>/dev/null || true
  codesign_args=(--force --sign "$SIGNING_IDENTITY")
  signing_mode="ad-hoc"
  if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign_args+=(--options runtime --timestamp)
    signing_mode="stable-developer-id"
  else
    echo "WARNING: PR/internal macOS artifact is ad-hoc signed. Its code identity changes between builds," >&2
    echo "so an existing legacy Keychain ACL can ask for permission again. Secrets remain encrypted." >&2
  fi
  if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    # Flutter's release output may contain ad-hoc-signed frameworks. A stable
    # outer signature is not sufficient: sign every nested framework with the
    # same Developer ID before sealing the application bundle.
    while IFS= read -r framework; do
      codesign "${codesign_args[@]}" "$framework"
    done < <(find "$STAGED_APP/Contents/Frameworks" -type d -name '*.framework' -print 2>/dev/null | sort)
  fi
  if [[ -f "$STAGED_APP/Contents/Frameworks/libreadarc_djvu_engine.dylib" ]]; then
    codesign "${codesign_args[@]}" "$STAGED_APP/Contents/Frameworks/libreadarc_djvu_engine.dylib"
  fi
  # Re-sign the modified outer bundle and explicitly restore its release
  # entitlements. A plain `codesign --deep` can discard Xcode-produced
  # entitlements. ReadArc intentionally uses the legacy encrypted macOS
  # Keychain because PR artifacts have no provisioning profile.
  codesign \
    "${codesign_args[@]}" \
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
    echo "ERROR: packaged ReadArc.app unexpectedly changes its Keychain access group." >&2
    exit 1
  fi
  codesign --verify --deep --strict "$STAGED_APP"
  {
    echo "mode=$signing_mode"
    echo "identity=$SIGNING_IDENTITY"
    echo "bundleIdentifier=com.readarc.readarc"
    echo "secureStorage=legacy-encrypted-keychain"
    echo "usesDataProtectionKeychain=false"
    codesign -dr - "$STAGED_APP" 2>&1 || true
  } > "$DIST_DIR/MACOS_SIGNING.txt"
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
