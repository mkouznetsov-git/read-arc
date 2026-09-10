import 'dart:async';

const defaultRelayCleanupTimeout = Duration(seconds: 2);

/// Waits for best-effort relay cleanup without allowing a stale transport to
/// block reconnect forever. This is especially important after macOS wakes
/// from sleep: the old websocket may remain half-open and never acknowledge
/// cancellation/close.
///
/// Returns true when cleanup completed normally, false when it timed out or
/// failed. Cleanup errors are intentionally contained here because the next
/// connection attempt is more valuable than keeping a dead transport alive.
Future<bool> waitForRelayCleanup(Future<void> cleanup, {Duration timeout = defaultRelayCleanupTimeout}) async {
  try {
    await cleanup.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  } catch (_) {
    return false;
  }
}
