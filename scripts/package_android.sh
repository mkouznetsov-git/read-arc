#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/android"
BASE_VERSION="${READARC_BASE_VERSION:-0.49.1}"
BUILD_NUMBER="${READARC_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 23)"
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Android build number must be numeric, got: $BUILD_NUMBER" >&2
  exit 1
fi

# Historical split-per-ABI packages used Flutter's automatic ABI_VERSION * 1000
# version-code adjustment. A user who installed one of those APKs cannot later
# install a universal APK with a small plain CI run number because Android sees
# it as a downgrade. Start a new sideload version-code epoch above every legacy
# ABI-adjusted code and force every APK/AAB flavor to use the same monotonic code.
ANDROID_VERSION_CODE_OFFSET="${READARC_ANDROID_VERSION_CODE_OFFSET:-10000}"
if [[ ! "$ANDROID_VERSION_CODE_OFFSET" =~ ^[0-9]+$ ]]; then
  echo "ERROR: READARC_ANDROID_VERSION_CODE_OFFSET must be numeric, got: $ANDROID_VERSION_CODE_OFFSET" >&2
  exit 1
fi
ANDROID_BUILD_NUMBER="${READARC_ANDROID_BUILD_NUMBER:-$((BUILD_NUMBER + ANDROID_VERSION_CODE_OFFSET))}"
if [[ ! "$ANDROID_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Android version code must be numeric, got: $ANDROID_BUILD_NUMBER" >&2
  exit 1
fi
if (( ANDROID_BUILD_NUMBER < 1 || ANDROID_BUILD_NUMBER > 2100000000 )); then
  echo "ERROR: Android versionCode must be between 1 and 2100000000, got: $ANDROID_BUILD_NUMBER" >&2
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
REQUIRE_RELEASE_SIGNING="${READARC_REQUIRE_RELEASE_SIGNING:-false}"
REQUIRE_NATIVE_ENGINES="${READARC_REQUIRE_NATIVE_ENGINES:-false}"

export READARC_PLATFORMS="android"
"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"
if [[ "$REQUIRE_RELEASE_SIGNING" == "true" && ! -f android/key.properties ]]; then
  echo "ERROR: release publishing requires android/key.properties from protected CI secrets." >&2
  exit 1
fi
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build and bundle the embedded DJVU engine when the Rust Android toolchain is available.
# If it is missing, Flutter packages still build; DJVU pages will show an in-app diagnostic
# instead of using external tools.
if "$ROOT_DIR/scripts/build_native_engines.sh" android; then
  for abi in armeabi-v7a arm64-v8a x86_64; do
    mkdir -p "android/app/src/main/jniLibs/$abi"
    cp "$ROOT_DIR/native/readarc_engines/dist/android/$abi/libreadarc_djvu_engine.so" "android/app/src/main/jniLibs/$abi/libreadarc_djvu_engine.so"
  done
else
  if [[ "$REQUIRE_NATIVE_ENGINES" == "true" ]]; then
    echo "ERROR: verified packages require every embedded Android engine." >&2
    exit 1
  fi
  echo "Embedded DJVU Android engine was not bundled. Continuing build without external converters." >&2
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

echo "Android versionName=$BUILD_NAME versionCode=$ANDROID_BUILD_NUMBER"
echo "Building Android universal release APK for simple sideload installation..."
build_with_optional_define build apk --release --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER"
if [[ -f build/app/outputs/flutter-apk/app-release.apk ]]; then
  cp build/app/outputs/flutter-apk/app-release.apk "$DIST_DIR/ReadArc-${VERSION}-android-universal-release.apk"
else
  echo "ERROR: universal release APK was not produced." >&2
  exit 1
fi

echo "Building Android release APKs split per ABI..."
build_with_optional_define build apk --release --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER" --split-per-abi

for apk in build/app/outputs/flutter-apk/*-release.apk; do
  [[ -f "$apk" ]] || continue
  base="$(basename "$apk")"
  case "$base" in
    app-arm64-v8a-release.apk)
      cp "$apk" "$DIST_DIR/ReadArc-${VERSION}-android-arm64-v8a-release.apk"
      ;;
    app-armeabi-v7a-release.apk)
      cp "$apk" "$DIST_DIR/ReadArc-${VERSION}-android-armeabi-v7a-release.apk"
      ;;
    app-x86_64-release.apk)
      cp "$apk" "$DIST_DIR/ReadArc-${VERSION}-android-x86_64-release.apk"
      ;;
    app-release.apk)
      # The universal APK from the previous build remains in Flutter's output
      # directory. It is already copied under the canonical universal name.
      ;;
    *)
      echo "ERROR: unexpected release APK output: $base" >&2
      exit 1
      ;;
  esac
done

echo "Building Android release App Bundle..."
build_with_optional_define build appbundle --release --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER"
if [[ -f build/app/outputs/bundle/release/app-release.aab ]]; then
  cp build/app/outputs/bundle/release/app-release.aab "$DIST_DIR/ReadArc-${VERSION}-android-release.aab"
else
  echo "ERROR: release App Bundle was not produced." >&2
  exit 1
fi

if [[ "$BUILD_DEBUG_ARTIFACTS" == "true" || "$BUILD_DEBUG_ARTIFACTS" == "1" ]]; then
  echo "Building optional Android debug APK..."
  build_with_optional_define build apk --debug --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER"
  cp build/app/outputs/flutter-apk/app-debug.apk "$DIST_DIR/ReadArc-${VERSION}-android-debug.apk"
fi

find_android_build_tool() {
  local tool="$1"
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || return 1
  find "$sdk_root/build-tools" -type f -name "$tool" -perm -u+x 2>/dev/null | sort -V | tail -n 1
}

APKSIGNER="$(find_android_build_tool apksigner || true)"
ZIPALIGN="$(find_android_build_tool zipalign || true)"
AAPT="$(find_android_build_tool aapt || true)"
if [[ -z "$APKSIGNER" || -z "$ZIPALIGN" || -z "$AAPT" ]]; then
  if [[ "$REQUIRE_RELEASE_SIGNING" == "true" ]]; then
    echo "ERROR: apksigner, zipalign and aapt are required to verify published Android APKs." >&2
    exit 1
  fi
  echo "WARNING: Android build tools unavailable; skipping local APK verification." >&2
else
  echo "Verifying final APK alignment, identity, version codes and signatures..."
  reference_fingerprint=""
  : > "$DIST_DIR/APK_METADATA.txt"
  for apk in "$DIST_DIR"/*-release.apk; do
    [[ -f "$apk" ]] || continue
    "$ZIPALIGN" -c -v 4 "$apk" >/dev/null
    verification="$($APKSIGNER verify --verbose --print-certs "$apk" 2>&1)"
    package_line="$($AAPT dump badging "$apk" | head -n 1)"
    package_name="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "$package_line")"
    version_code="$(sed -n "s/^package: .* versionCode='\([^']*\)'.*/\1/p" <<< "$package_line")"
    version_name="$(sed -n "s/^package: .* versionName='\([^']*\)'.*/\1/p" <<< "$package_line")"
    fingerprint="$(sed -n 's/.*certificate SHA-256 digest:[[:space:]]*//p' <<< "$verification" | tr -d '\r' | head -n 1)"
    if [[ "$package_name" != "com.readarc.readarc" ]]; then
      echo "ERROR: unexpected applicationId in $(basename "$apk"): $package_name" >&2
      exit 1
    fi
    if [[ "$version_code" != "$ANDROID_BUILD_NUMBER" ]]; then
      echo "ERROR: unexpected versionCode in $(basename "$apk"): expected=$ANDROID_BUILD_NUMBER actual=$version_code" >&2
      exit 1
    fi
    if [[ "$version_name" != "$BUILD_NAME" ]]; then
      echo "ERROR: unexpected versionName in $(basename "$apk"): expected=$BUILD_NAME actual=$version_name" >&2
      exit 1
    fi
    if [[ -z "$fingerprint" ]]; then
      echo "ERROR: certificate fingerprint is missing in $(basename "$apk")." >&2
      printf '%s\n' "$verification" >&2
      exit 1
    fi
    if [[ -n "$reference_fingerprint" && "$fingerprint" != "$reference_fingerprint" ]]; then
      echo "ERROR: release APK signing certificates are inconsistent." >&2
      exit 1
    fi
    reference_fingerprint="$fingerprint"
    {
      echo "file=$(basename "$apk")"
      echo "package=$package_name"
      echo "versionCode=$version_code"
      echo "versionName=$version_name"
      echo "displayBuild=$BUILD_NAME ($BUILD_NUMBER)"
      echo "certificateSha256=$fingerprint"
      echo "zipaligned=true"
      echo
    } >> "$DIST_DIR/APK_METADATA.txt"
  done
  if [[ -z "$reference_fingerprint" ]]; then
    echo "ERROR: no release APKs were available for verification." >&2
    exit 1
  fi
fi

if command -v jarsigner >/dev/null 2>&1; then
  for aab in "$DIST_DIR"/*.aab; do
    [[ -f "$aab" ]] || continue
    jarsigner -verify "$aab" >/dev/null
  done
fi

(
  cd "$DIST_DIR"
  shasum -a 256 * > SHA256SUMS
)

echo "Android artifacts:"
ls -lh "$DIST_DIR"
echo
echo "Android artifact sizes:"
du -h "$DIST_DIR"/* | sort -h
