import 'package:flutter/material.dart';

/// Holds a reader route open until its latest progress checkpoint reaches the
/// local manifest. This covers app-bar, classic system Back and predictive Back
/// without making route disposal responsible for the durable write.
class ReaderExitCheckpoint extends StatefulWidget {
  const ReaderExitCheckpoint({super.key, required this.onCommit, required this.child});

  final Future<void> Function() onCommit;
  final Widget child;

  @override
  State<ReaderExitCheckpoint> createState() => _ReaderExitCheckpointState();
}

class _ReaderExitCheckpointState extends State<ReaderExitCheckpoint> {
  bool _allowPop = false;
  bool _commitInProgress = false;

  Future<void> _onPopInvoked(bool didPop, Object? _) async {
    if (didPop || _commitInProgress) return;
    _commitInProgress = true;
    try {
      await widget.onCommit();
    } catch (error, stackTrace) {
      debugPrint('Reader exit progress checkpoint failed: $error\n$stackTrace');
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(canPop: _allowPop, onPopInvokedWithResult: _onPopInvoked, child: widget.child);
  }
}
