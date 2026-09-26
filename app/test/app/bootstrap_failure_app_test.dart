import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/bootstrap_failure_app.dart';

void main() {
  testWidgets('names the error and where the log is', (tester) async {
    await tester.pumpWidget(
      BootstrapFailureApp(
        error: const FileSystemException('database is locked', r'C:\k\app.db'),
        stack: StackTrace.current,
        logDirectory: Directory(r'C:\k\logs'),
      ),
    );
    expect(find.text('Karmashala could not start'), findsOneWidget);
    expect(find.textContaining('database is locked'), findsOneWidget);
    expect(find.textContaining(r'C:\k\logs'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Copy details'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Quit'), findsOneWidget);
  });

  testWidgets('no log directory, no log line', (tester) async {
    await tester.pumpWidget(const BootstrapFailureApp(error: 'x', stack: null));
    expect(find.textContaining('Log:'), findsNothing);
  });
}
