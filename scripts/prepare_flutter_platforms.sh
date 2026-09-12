#!/usr/bin/env bash
set -euo pipefail

# Sprint 45: platform projects are source-controlled. This script validates
# them and resolves only the locked Dart/Flutter dependency graph.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
PLATFORMS="${READARC_PLATFORMS:-android,macos,ios}"
EXPECTED_FLUTTER_VERSION="3.47.0"

cd "$APP_DIR"

actual_flutter_version="$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
if [[ "$actual_flutter_version" != "$EXPECTED_FLUTTER_VERSION" ]]; then
  echo "ERROR: Flutter $EXPECTED_FLUTTER_VERSION is required; found $actual_flutter_version." >&2
  exit 1
fi

IFS=',' read -r -a requested_platforms <<< "$PLATFORMS"
for platform in "${requested_platforms[@]}"; do
  case "$platform" in
    android|macos|ios)
      if [[ ! -d "$platform" ]]; then
        echo "ERROR: committed Flutter platform directory is missing: $platform" >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: unsupported READARC_PLATFORMS entry: $platform" >&2
      exit 64
      ;;
  esac
done

if [[ "$PLATFORMS" == *android* ]]; then
  grep -q 'compileSdk = 36' android/app/build.gradle.kts
  grep -q 'android.permission.INTERNET' android/app/src/main/AndroidManifest.xml
  grep -q 'android.permission.CAMERA' android/app/src/main/AndroidManifest.xml
  grep -q 'android:usesCleartextTraffic="false"' android/app/src/main/AndroidManifest.xml
  grep -q '^force-version-code-ignoring-abi=true$' android/gradle.properties
  grep -q 'ACTION_OPEN_DOCUMENT_TREE' android/app/src/main/kotlin/com/readarc/readarc/MainActivity.kt
  grep -q 'takePersistableUriPermission' android/app/src/main/kotlin/com/readarc/readarc/MainActivity.kt
  if [[ -n "$(git -C "$ROOT_DIR" ls-files -- \
    'apps/flutter_client/android/app/*.jks' \
    'apps/flutter_client/android/app/*.keystore')" ]]; then
    echo "ERROR: Android signing keys must not be committed under android/app." >&2
    exit 1
  fi
fi

if [[ "$PLATFORMS" == *macos* ]]; then
  grep -q 'PRODUCT_NAME = ReadArc' macos/Runner/Configs/AppInfo.xcconfig
  grep -q 'com.apple.security.network.client' macos/Runner/Release.entitlements
  grep -q 'com.apple.security.files.user-selected.read-write' macos/Runner/Release.entitlements
  python3 - <<'PY'
import plistlib
from pathlib import Path

for path in (
    Path('macos/Runner/DebugProfile.entitlements'),
    Path('macos/Runner/Release.entitlements'),
):
    with path.open('rb') as source:
        entitlements = plistlib.load(source)
    if 'keychain-access-groups' in entitlements:
        raise SystemExit(
            f'ERROR: {path} must not require Keychain Sharing while ReadArc '
            'is distributed as an ad-hoc signed macOS app.'
        )
PY
  grep -q 'usesDataProtectionKeychain: false' lib/services/library_repository.dart
  grep -q 'withSecurityScope' macos/Runner/MainFlutterWindow.swift
  grep -q 'startAccessingSecurityScopedResource' macos/Runner/MainFlutterWindow.swift
fi

if [[ "$PLATFORMS" == *ios* ]]; then
  grep -q '<string>ReadArc</string>' ios/Runner/Info.plist
  grep -q '<key>NSCameraUsageDescription</key>' ios/Runner/Info.plist
  grep -q 'UIDocumentPickerViewController' ios/Runner/AppDelegate.swift
  grep -q 'startAccessingSecurityScopedResource' ios/Runner/AppDelegate.swift
fi

flutter pub get --enforce-lockfile
echo "Committed Flutter platform validation complete: $PLATFORMS"
