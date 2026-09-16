import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/bootstrap_failure_app.dart';
import 'package:karmashala/src/app/shell/karmashala_about_dialog.dart';

import '../support/window_matrix.dart';

/// The shell's own small surfaces, through the window matrix.

/// Twice the text, where a fixed-width body or a fixed-height row gives out.
const _minimumWindowDoubleText = WindowCell(
  '720x560 @ 2x text',
  Size(720, 560),
  textScale: 2,
);

void main() {
  testWidgets('the About dialog', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: () => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: KarmashalaAboutDialog(),
      ),
      matrix: const [
        ...windowMatrix,
        desktopLargeText,
        _minimumWindowDoubleText,
      ],
      because: 'the body was a fixed 520 wide and did not scroll',
    );
  });

  group('the bootstrap failure screen', () {
    // What a real start-up failure can look like: an exception with a path, a
    // chained cause and a stack's worth of detail in its message.
    final longError = List.filled(
      30,
      'database is locked (C:\\Users\\k\\AppData\\karmashala.db) ',
    ).join();

    testWidgets('a long error keeps its buttons in the window', (tester) async {
      expect(longError.length, greaterThan(1500));
      await expectSurvivesWindowMatrix(
        tester,
        build: () => BootstrapFailureApp(
          error: longError,
          stack: null,
          logDirectory: Directory(r'C:\k\logs'),
        ),
        because: 'the error did not scroll, so it pushed the buttons out',
      );
    });

    testWidgets('a short error at twice the text', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => BootstrapFailureApp(
          error: longError.substring(0, 400),
          stack: null,
          logDirectory: Directory(r'C:\k\logs'),
        ),
        matrix: const [_minimumWindowDoubleText],
        because: 'a 400-character error overflowed at 2x text',
      );
    });
  });
}
