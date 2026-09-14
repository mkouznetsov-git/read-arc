#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 OLD_APK NEW_APK [REPORT_FILE]" >&2
  exit 2
fi

OLD_APK="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NEW_APK="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
REPORT_FILE="${3:-android-upgrade-smoke.txt}"
PACKAGE_ID="com.readarc.readarc"
SENTINEL="readarc-upgrade-data-preserved"
APP_DATA_ROOT="/data/user/0/$PACKAGE_ID"
MANIFEST_PATH="$APP_DATA_ROOT/app_flutter/ReadArc/manifest.json"
LIBRARY_ROOT_PATH="$APP_DATA_ROOT/app_flutter/ReadArc/library_root.json"

for apk in "$OLD_APK" "$NEW_APK"; do
  if [[ ! -f "$apk" ]]; then
    echo "ERROR: APK not found: $apk" >&2
    exit 1
  fi
done

find_android_tool() {
  local tool="$1"
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  [[ -n "$sdk_root" && -d "$sdk_root" ]] || return 1
  find "$sdk_root" -type f -name "$tool" -perm -u+x 2>/dev/null | sort -V | tail -n 1
}

APKSIGNER="$(find_android_tool apksigner || true)"
AAPT="$(find_android_tool aapt || true)"
if [[ -z "$APKSIGNER" || -z "$AAPT" ]]; then
  echo "ERROR: apksigner and aapt are required for the Android upgrade smoke test." >&2
  exit 1
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb is required for the Android upgrade smoke test." >&2
  exit 1
fi

apk_package() {
  "$AAPT" dump badging "$1" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1
}

apk_version_code() {
  "$AAPT" dump badging "$1" | sed -n "s/^package: .* versionCode='\([^']*\)'.*/\1/p" | head -n 1
}

apk_fingerprint() {
  "$APKSIGNER" verify --print-certs "$1" 2>&1 |
    sed -n 's/.*certificate SHA-256 digest:[[:space:]]*//p' |
    tr -d '\r' |
    head -n 1
}

ORIGINAL_OLD_FINGERPRINT="$(apk_fingerprint "$OLD_APK")"
ORIGINAL_NEW_FINGERPRINT="$(apk_fingerprint "$NEW_APK")"
MAX_OLD_VERSION_CODE=0
OLD_RELEASE_COUNT=0
for old_release_apk in "$(dirname "$OLD_APK")"/*-android-*-release.apk; do
  [[ -f "$old_release_apk" ]] || continue
  old_release_package="$(apk_package "$old_release_apk")"
  old_release_version="$(apk_version_code "$old_release_apk")"
  old_release_fingerprint="$(apk_fingerprint "$old_release_apk")"
  if [[ "$old_release_package" != "$PACKAGE_ID" ]]; then
    echo "ERROR: previous release applicationId changed in $(basename "$old_release_apk"): $old_release_package" >&2
    exit 1
  fi
  if [[ ! "$old_release_version" =~ ^[0-9]+$ ]]; then
    echo "ERROR: previous release has a non-numeric versionCode: $(basename "$old_release_apk")" >&2
    exit 1
  fi
  if [[ "$old_release_fingerprint" != "$ORIGINAL_OLD_FINGERPRINT" ]]; then
    echo "ERROR: previous release APK certificates are inconsistent." >&2
    exit 1
  fi
  if (( old_release_version > MAX_OLD_VERSION_CODE )); then
    MAX_OLD_VERSION_CODE="$old_release_version"
  fi
  OLD_RELEASE_COUNT=$((OLD_RELEASE_COUNT + 1))
done
if (( OLD_RELEASE_COUNT < 4 )); then
  echo "ERROR: expected universal and three ABI APKs from the previous release; found $OLD_RELEASE_COUNT." >&2
  exit 1
fi
TEST_OLD_APK="$OLD_APK"
TEST_NEW_APK="$NEW_APK"
TEMP_DIRECTORY="$(mktemp -d)"

cleanup() {
  adb shell am force-stop "$PACKAGE_ID" >/dev/null 2>&1 || true
  adb uninstall "$PACKAGE_ID" >/dev/null 2>&1 || true
  if [[ -d "$TEMP_DIRECTORY" ]]; then
    rm -rf "$TEMP_DIRECTORY"
  fi
}
trap cleanup EXIT

# Pull-request jobs cannot receive the production signing key safely. They
# re-sign copies of the already-verified old/new APKs with one ephemeral key so
# the exact package contents, version ordering and adb upgrade semantics are
# still exercised. Main uses the untouched production-signed APKs.
if [[ "${READARC_RESIGN_UPGRADE_FIXTURES:-false}" == "true" ]]; then
  keytool -genkeypair \
    -keystore "$TEMP_DIRECTORY/upgrade-smoke.jks" \
    -storepass readarc-ci-only \
    -keypass readarc-ci-only \
    -alias readarc-ci \
    -keyalg RSA \
    -keysize 2048 \
    -validity 2 \
    -dname 'CN=ReadArc CI upgrade smoke' >/dev/null 2>&1
  "$APKSIGNER" sign \
    --ks "$TEMP_DIRECTORY/upgrade-smoke.jks" \
    --ks-key-alias readarc-ci \
    --ks-pass pass:readarc-ci-only \
    --key-pass pass:readarc-ci-only \
    --out "$TEMP_DIRECTORY/old.apk" \
    "$OLD_APK"
  "$APKSIGNER" sign \
    --ks "$TEMP_DIRECTORY/upgrade-smoke.jks" \
    --ks-key-alias readarc-ci \
    --ks-pass pass:readarc-ci-only \
    --key-pass pass:readarc-ci-only \
    --out "$TEMP_DIRECTORY/new.apk" \
    "$NEW_APK"
  TEST_OLD_APK="$TEMP_DIRECTORY/old.apk"
  TEST_NEW_APK="$TEMP_DIRECTORY/new.apk"
fi

for apk in "$TEST_OLD_APK" "$TEST_NEW_APK"; do
  "$APKSIGNER" verify --verbose --print-certs "$apk" >/dev/null
done

OLD_PACKAGE="$(apk_package "$TEST_OLD_APK")"
NEW_PACKAGE="$(apk_package "$TEST_NEW_APK")"
OLD_VERSION_CODE="$(apk_version_code "$TEST_OLD_APK")"
NEW_VERSION_CODE="$(apk_version_code "$TEST_NEW_APK")"
OLD_FINGERPRINT="$(apk_fingerprint "$TEST_OLD_APK")"
NEW_FINGERPRINT="$(apk_fingerprint "$TEST_NEW_APK")"

if [[ "$OLD_PACKAGE" != "$PACKAGE_ID" || "$NEW_PACKAGE" != "$PACKAGE_ID" ]]; then
  echo "ERROR: applicationId changed: old=$OLD_PACKAGE new=$NEW_PACKAGE" >&2
  exit 1
fi
if [[ ! "$OLD_VERSION_CODE" =~ ^[0-9]+$ || ! "$NEW_VERSION_CODE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: non-numeric APK versionCode: old=$OLD_VERSION_CODE new=$NEW_VERSION_CODE" >&2
  exit 1
fi
if (( NEW_VERSION_CODE <= OLD_VERSION_CODE )); then
  echo "ERROR: versionCode is not monotonic: old=$OLD_VERSION_CODE new=$NEW_VERSION_CODE" >&2
  exit 1
fi
if (( NEW_VERSION_CODE <= MAX_OLD_VERSION_CODE )); then
  echo "ERROR: new universal versionCode=$NEW_VERSION_CODE is not above every previous split APK; max=$MAX_OLD_VERSION_CODE" >&2
  exit 1
fi
if [[ -z "$OLD_FINGERPRINT" || "$OLD_FINGERPRINT" != "$NEW_FINGERPRINT" ]]; then
  echo "ERROR: signing certificate mismatch: old=$OLD_FINGERPRINT new=$NEW_FINGERPRINT" >&2
  exit 1
fi

adb wait-for-device
adb root >/tmp/readarc-adb-root.txt
adb wait-for-device
if [[ "$(adb shell id -u | tr -d '\r')" != "0" ]]; then
  echo "ERROR: the package-upgrade emulator must provide root access to inspect non-debuggable release app data." >&2
  cat /tmp/readarc-adb-root.txt >&2
  exit 1
fi
adb install -r "$TEST_OLD_APK"
APP_UID="$(adb shell stat -c %u "$APP_DATA_ROOT" | tr -d '\r')"
if [[ ! "$APP_UID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not determine the installed app UID." >&2
  exit 1
fi
BOOK_PATH="$APP_DATA_ROOT/app_flutter/ReadArc/books/upgrade.txt"
python3 - "$TEMP_DIRECTORY/old-manifest.json" "$BOOK_PATH" <<'PY'
import json
import pathlib
import sys

manifest = {
    'accountId': 'android-upgrade-account',
    'accountEncryptionKey': 'android-upgrade-account-secret',
    'deviceId': 'android-upgrade-device',
    'deviceName': 'Previous Android device',
    'deviceSigningPublicKey': 'android-upgrade-public',
    'deviceSigningPrivateKey': 'android-upgrade-private-secret',
    'updatedAt': '2026-01-01T00:00:00.000Z',
    'trustedDevices': [
        {'deviceId': 'android-upgrade-device', 'name': 'Previous Android device', 'role': 'owner'},
        {'deviceId': 'paired-device', 'name': 'Paired device', 'role': 'device'},
    ],
    'books': [{
        'id': 'android-upgrade-book',
        'title': 'Preserved Android upgrade book',
        'fileName': 'upgrade.txt',
        'format': 'txt',
        'sizeBytes': 29,
        'contentSha256': 'android-upgrade-sha256',
        'localPath': sys.argv[2],
        'addedAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-02T00:00:00.000Z',
        'progressPercent': 64,
        'currentLocator': 'paragraph:42',
        'progressVersion': 7,
        'updatedByDeviceId': 'android-upgrade-device',
        'availableOnDeviceIds': ['android-upgrade-device'],
        'bookmarks': [{
            'id': 'android-upgrade-bookmark',
            'bookId': 'android-upgrade-book',
            'label': 'Preserved bookmark',
            'locator': 'paragraph:42',
            'note': 'Upgrade must retain this note',
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
        }],
    }],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(manifest))
PY
printf '%s' 'preserved Android book payload' > "$TEMP_DIRECTORY/upgrade.txt"
printf '%s' "$SENTINEL" > "$TEMP_DIRECTORY/upgrade-sentinel"
adb shell "mkdir -p '$APP_DATA_ROOT/app_flutter/ReadArc/books' '$APP_DATA_ROOT/files'"
adb push "$TEMP_DIRECTORY/old-manifest.json" "$MANIFEST_PATH" >/dev/null
adb push "$TEMP_DIRECTORY/upgrade.txt" "$BOOK_PATH" >/dev/null
adb push "$TEMP_DIRECTORY/upgrade-sentinel" "$APP_DATA_ROOT/files/upgrade-sentinel" >/dev/null
adb shell "chown -R '$APP_UID:$APP_UID' '$APP_DATA_ROOT/app_flutter' '$APP_DATA_ROOT/files'"
if [[ "$(adb shell "cat '$APP_DATA_ROOT/files/upgrade-sentinel'" | tr -d '\r')" != "$SENTINEL" ]]; then
  echo "ERROR: could not create application-data sentinel before upgrade." >&2
  exit 1
fi

adb install -r "$TEST_NEW_APK" | tee /tmp/readarc-adb-upgrade.txt
grep -q '^Success$' /tmp/readarc-adb-upgrade.txt
if [[ "$(adb shell "cat '$APP_DATA_ROOT/files/upgrade-sentinel'" | tr -d '\r')" != "$SENTINEL" ]]; then
  echo "ERROR: application data was lost during adb install -r." >&2
  exit 1
fi
adb shell am start -W -n "$PACKAGE_ID/.MainActivity" | tee /tmp/readarc-new-launch.txt
grep -q 'Status: ok' /tmp/readarc-new-launch.txt
for attempt in {1..100}; do
  adb exec-out cat "$MANIFEST_PATH" > "$TEMP_DIRECTORY/new-manifest.json" 2>/dev/null || true
  if python3 - "$TEMP_DIRECTORY/new-manifest.json" <<'PY'
import json
import pathlib
import sys

try:
    manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if manifest.get('schemaVersion') == 3 else 1)
PY
  then
    break
  fi
  sleep 0.2
done
if ! python3 - "$TEMP_DIRECTORY/new-manifest.json" <<'PY'
import json
import pathlib
import sys

try:
    manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if manifest.get('schemaVersion') == 3 else 1)
PY
then
  echo "ERROR: upgraded release did not finish migrating its manifest." >&2
  exit 1
fi
if adb shell "test -e '$LIBRARY_ROOT_PATH'"; then
  echo "ERROR: ReadArc silently created a canonical library root during package upgrade." >&2
  exit 1
fi
python3 - "$TEMP_DIRECTORY/old-manifest.json" "$TEMP_DIRECTORY/new-manifest.json" <<'PY'
import json
import pathlib
import sys

old = json.loads(pathlib.Path(sys.argv[1]).read_text())
new = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert new['schemaVersion'] == 3
assert 'accountEncryptionKey' not in new
assert 'deviceSigningPrivateKey' not in new
assert new['accountId'] == old['accountId']
assert new['deviceId'] == old['deviceId']
assert {book['id'] for book in new['books']} == {book['id'] for book in old['books']}
assert {device['deviceId'] for device in new['trustedDevices']} == {
    device['deviceId'] for device in old['trustedDevices']
}
book = new['books'][0]
assert book['progressPercent'] == 64
assert book['currentLocator'] == 'paragraph:42'
assert book['progressRevision']['counter'] == 7
assert book['bookmarks'][0]['id'] == 'android-upgrade-bookmark'
assert book['bookmarks'][0]['note'] == 'Upgrade must retain this note'
PY
if [[ "$(adb shell "cat '$BOOK_PATH'" | tr -d '\r')" != 'preserved Android book payload' ]]; then
  echo "ERROR: application book data was lost during adb install -r." >&2
  exit 1
fi

mkdir -p "$(dirname "$REPORT_FILE")"
{
  echo "ANDROID_UPGRADE_SMOKE_OK"
  echo "package=$PACKAGE_ID"
  echo "oldVersionCode=$OLD_VERSION_CODE"
  echo "maxPreviousReleaseVersionCode=$MAX_OLD_VERSION_CODE"
  echo "newVersionCode=$NEW_VERSION_CODE"
  echo "originalOldCertificateSha256=$ORIGINAL_OLD_FINGERPRINT"
  echo "originalNewCertificateSha256=$ORIGINAL_NEW_FINGERPRINT"
  echo "testedCertificateSha256=$NEW_FINGERPRINT"
  echo "resignedFixtures=${READARC_RESIGN_UPGRADE_FIXTURES:-false}"
  echo "dataPreserved=true"
  echo "legacySchemaV1ToV2ToV3=true"
  echo "booksProgressBookmarksPairingPreserved=true"
  echo "accountAndDeviceIdentityPreserved=true"
  echo "libraryRootSelectionRequired=true"
  echo "legacySourceRetainedUntilVerifiedMigration=true"
  echo "launchAfterUpgrade=true"
} | tee "$REPORT_FILE"
