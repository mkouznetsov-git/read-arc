import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/reader/reader_exit_checkpoint.dart';

void main() {
  testWidgets('system Back persists the current PDF locator before returning to the library', (tester) async {
    String? persistedLocator;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ReaderExitCheckpoint(
                    onCommit: () async {
                      persistedLocator = jsonEncode({'type': 'pdf-page-v1', 'page': 2, 'pages': 2});
                    },
                    child: const Scaffold(body: Text('PDF page 2')),
                  ),
                ),
              ),
              child: const Text('Open PDF'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open PDF'));
    await tester.pumpAndSettle();
    expect(find.text('PDF page 2'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open PDF'), findsOneWidget);

    final locator = jsonDecode(persistedLocator!) as Map<String, dynamic>;
    expect(locator['type'], 'pdf-page-v1');
    expect(locator['page'], 2);
  });
}
