import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) => File(relativePath).readAsStringSync();

void main() {
  group('ReadArc regression contracts', () {
    test('active product code never falls back to ReadAnywhere', () {
      final roots = <String>[
        '../../scripts/prepare_flutter_platforms.sh',
        'lib/main.dart',
        'lib/app/readarc_app.dart',
        'pubspec.yaml',
      ];
      final forbidden = RegExp(r'ReadAnywhere|Read Anywhere|readanywhere|read-anywhere|read_anywhere|READANYWHERE');
      final offenders = <String>[];
      for (final path in roots) {
        final file = File(path);
        if (!file.existsSync()) continue;
        if (forbidden.hasMatch(file.readAsStringSync())) offenders.add(path);
      }
      expect(offenders, isEmpty, reason: 'Legacy ReadAnywhere naming returned in active code: ${offenders.join(', ')}');
    });

    test('QR scanner stays on the known working backend', () {
      final pubspec = _read('pubspec.yaml');
      final main = _read('lib/app/readarc_app.dart');
      expect(pubspec, contains('qr_code_scanner_plus:'));
      expect(main, contains("package:qr_code_scanner_plus/qr_code_scanner_plus.dart"));
      expect(pubspec, isNot(contains('mobile_scanner:')));
      expect(main, isNot(contains("package:mobile_scanner/mobile_scanner.dart")));
    });

    test('committed Android project preserves QR permissions and cleartext boundary', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      final debugManifest = _read('android/app/src/debug/AndroidManifest.xml');
      final pubspec = _read('pubspec.yaml');
      final platformValidator = _read('../../scripts/prepare_flutter_platforms.sh');
      expect(manifest, contains('android.permission.CAMERA'));
      expect(manifest, contains('android.permission.INTERNET'));
      expect(manifest, contains('android:usesCleartextTraffic="false"'));
      expect(debugManifest, contains('android:usesCleartextTraffic="true"'));
      expect(debugManifest, contains('xmlns:tools="http://schemas.android.com/tools"'));
      expect(debugManifest, contains('tools:replace="android:usesCleartextTraffic"'));
      expect(pubspec, contains('file_picker: 10.3.10'));
      expect(pubspec, isNot(contains('dependency_overrides:')));
      expect(pubspec, contains('qr_code_scanner_plus:'));
      expect(platformValidator, contains('git -C "\$ROOT_DIR" ls-files'));
      expect(platformValidator, isNot(contains('find android/app')));
    });

    test('production package upgrade gates cannot be silently removed', () {
      final gradleProperties = _read('android/gradle.properties');
      final pubspec = _read('pubspec.yaml');
      final lockfile = _read('pubspec.lock');
      final androidPackager = _read('../../scripts/package_android.sh');
      final androidUpgrade = _read('../../scripts/android_upgrade_smoke.sh');
      final androidUpgradeCi = _read('../../scripts/run_android_upgrade_smoke_ci.sh');
      final macosUpgrade = _read('../../scripts/macos_package_upgrade_smoke.sh');
      final workflow = _read('../../.github/workflows/quality_gate.yml');

      expect(gradleProperties, contains('force-version-code-ignoring-abi=true'));
      expect(androidPackager, contains('version_code" != "\$ANDROID_BUILD_NUMBER'));
      expect(androidPackager, contains('certificateSha256='));
      expect(androidUpgrade, contains('adb install -r'));
      expect(androidUpgrade, contains('adb root'));
      expect(androidUpgrade, contains('upgrade-sentinel'));
      expect(androidUpgrade, contains('OLD_FINGERPRINT" != "\$NEW_FINGERPRINT'));
      expect(androidUpgradeCi, contains('android_upgrade_smoke.sh'));
      expect(macosUpgrade, contains('legacySchemaV1ToV2ToV3=true'));
      expect(macosUpgrade, contains('booksProgressBookmarksPairingPreserved=true'));
      expect(workflow, contains('Run packaged Android adb install -r upgrade test'));
      expect(workflow, contains('Configure ephemeral Android signing for pull-request verification'));
      expect(workflow, contains('Run packaged macOS clean and legacy-library upgrade test'));
      expect(pubspec, contains('flutter_secure_storage: 10.3.0'));
      expect(lockfile, contains('flutter_secure_storage_darwin'));
      expect(lockfile, contains('version: "0.3.2"'));
    });

    test('pairing UI remains six-digit-code based', () {
      final main = _read('lib/app/readarc_app.dart');
      expect(main, contains('Создать код подключения'));
      expect(main, contains('Показать QR'));
      expect(main, contains('Введите код приглашения'));
      expect(main, contains('Введите код на подключаемом устройстве'));
    });

    test('library download paths remain guarded by relay connectivity', () {
      final main = _read('lib/app/readarc_app.dart');
      expect(main, contains("if (!widget.sync.state.value.connected)"));
      expect(main, contains('Нет подключения к relay.'));
    });

    test('critical reader routes remain registered', () {
      final main = _read('lib/app/readarc_app.dart');
      for (final extension in ['pdf', 'djvu', 'epub', 'fb2', 'txt', 'docx', 'doc']) {
        expect(main, contains("case '$extension':"), reason: 'Reader route for .$extension disappeared');
      }
    });

    test('stateful readers checkpoint current progress before system Back completes', () {
      final main = _read('lib/app/readarc_app.dart');
      for (final state in [
        '_TxtReaderScreenState',
        '_DocxReaderScreenState',
        '_Fb2ReaderScreenState',
        '_DjvuReaderScreenState',
        '_PdfReaderScreenState',
      ]) {
        final body = RegExp('class ${RegExp.escape(state)}[\\s\\S]*?(?=\\nclass )').firstMatch(main)?.group(0);
        expect(body, isNotNull, reason: '$state disappeared');
        expect(
          body,
          contains('ReaderExitCheckpoint(onCommit: _commitProgressBeforePop'),
          reason: '$state no longer waits for its durable exit checkpoint',
        );
      }

      for (final state in ['_DjvuReaderScreenState', '_PdfReaderScreenState']) {
        final body = RegExp('class ${RegExp.escape(state)}[\\s\\S]*?(?=\\nclass )').firstMatch(main)?.group(0);
        expect(body, contains('unawaited(_savePage(_page))'), reason: '$state lost its non-pop disposal fallback');
      }
    });
  });
}
