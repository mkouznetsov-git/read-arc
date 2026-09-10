import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/reader/reader_exit_checkpoint.dart';

void main() {
  testWidgets('system Back waits for the durable reader checkpoint before popping', (tester) async {
    final commitStarted = Completer<void>();
    final allowCommit = Completer<void>();
    var commitCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ReaderExitCheckpoint(
                    onCommit: () async {
                      commitCalls += 1;
                      commitStarted.complete();
                      await allowCommit.future;
                    },
                    child: const Scaffold(body: Text('Reader route')),
                  ),
                ),
              ),
              child: const Text('Open reader'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open reader'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await commitStarted.future;
    await tester.pump();

    expect(commitCalls, 1);
    expect(find.text('Reader route'), findsOneWidget);
    expect(find.text('Open reader'), findsNothing);

    allowCommit.complete();
    await tester.pumpAndSettle();

    expect(find.text('Reader route'), findsNothing);
    expect(find.text('Open reader'), findsOneWidget);
  });
}
