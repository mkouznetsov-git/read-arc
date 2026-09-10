import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/services/sync/relay_lifecycle_guard.dart';

void main() {
  test('stuck relay cleanup cannot block reconnect indefinitely', () async {
    final neverCompletes = Completer<void>();
    final stopwatch = Stopwatch()..start();

    final completed = await waitForRelayCleanup(neverCompletes.future, timeout: const Duration(milliseconds: 25));

    stopwatch.stop();
    expect(completed, isFalse);
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(milliseconds: 250)),
      reason: 'post-sleep reconnect must continue even if the stale websocket never acknowledges close',
    );
  });

  test('normal relay cleanup still reports completion', () async {
    final completed = await waitForRelayCleanup(Future<void>.value(), timeout: const Duration(milliseconds: 25));

    expect(completed, isTrue);
  });
}
