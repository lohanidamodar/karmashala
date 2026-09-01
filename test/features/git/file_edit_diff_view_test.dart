import 'package:chitragupta/src/app/theme/app_theme.dart';
import 'package:chitragupta/src/features/git/data/file_edit_diff.dart';
import 'package:chitragupta/src/features/git/domain/file_edit.dart';
import 'package:chitragupta/src/features/git/presentation/file_edit_diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _modified = FileEditRecord(
  path: '/repo/lib/a.dart',
  kind: FileEditKind.modified,
  toolName: 'Edit',
  oldText: 'one\ntwo\nthree\n',
  newText: 'one\nTWO\nthree\n',
);

void main() {
  setUp(clearFileEditDiffCache);

  Future<void> pump(
    WidgetTester tester,
    FileEditRecord record, {
    Size size = const Size(1440, 900),
    Key? key,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: FileEditDiffCard(key: key, record: record)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('names the file and summarises the change before expanding', (
    tester,
  ) async {
    await pump(tester, _modified);

    expect(find.text('a.dart'), findsOneWidget);
    // The change type is a word, not only a colour.
    expect(find.text('Modified'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('-1'), findsOneWidget);
    // Collapsed by default, like the Changes panel.
    expect(find.text('+TWO'), findsNothing);
  });

  testWidgets('expanding shows the diff, signed so colour is never the only '
      'signal', (tester) async {
    await pump(tester, _modified);
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();

    expect(find.text('-two'), findsOneWidget);
    expect(find.text('+TWO'), findsOneWidget);
    expect(find.text(' one'), findsOneWidget);
  });

  testWidgets('a new file reads as created and is all additions', (
    tester,
  ) async {
    await pump(
      tester,
      const FileEditRecord(
        path: '/repo/new.txt',
        kind: FileEditKind.created,
        toolName: 'Write',
        newText: 'a\nb\n',
      ),
    );
    await tester.tap(find.text('new.txt'));
    await tester.pumpAndSettle();

    expect(find.text('Created'), findsOneWidget);
    expect(find.text('+a'), findsOneWidget);
    expect(find.text('+b'), findsOneWidget);
  });

  testWidgets('a deleted file reads as deleted and is all removals', (
    tester,
  ) async {
    await pump(
      tester,
      const FileEditRecord(
        path: '/repo/gone.txt',
        kind: FileEditKind.deleted,
        oldText: 'a\nb\n',
      ),
    );
    await tester.tap(find.text('gone.txt'));
    await tester.pumpAndSettle();

    expect(find.text('Deleted'), findsOneWidget);
    expect(find.text('-a'), findsOneWidget);
    expect(find.text('-b'), findsOneWidget);
  });

  testWidgets('a binary file says why there is no diff', (tester) async {
    await pump(
      tester,
      const FileEditRecord(
        path: '/repo/logo.png',
        kind: FileEditKind.created,
        newText: 'PNG\u0000\u001a\nIHDR\u0000',
      ),
    );
    await tester.tap(find.text('logo.png'));
    await tester.pumpAndSettle();

    expect(find.textContaining('binary'), findsOneWidget);
  });

  testWidgets('a diff too large to compute says so instead of freezing', (
    tester,
  ) async {
    final huge = List.filled(60000, 'a line of text').join('\n');
    await pump(
      tester,
      FileEditRecord(
        path: '/repo/huge.txt',
        kind: FileEditKind.modified,
        oldText: huge,
        newText: '$huge\nmore',
      ),
    );
    await tester.tap(find.text('huge.txt'));
    await tester.pumpAndSettle();

    expect(find.textContaining('too large'), findsOneWidget);
  });

  testWidgets('a very long diff is shown truncated, and says it was', (
    tester,
  ) async {
    final patch = [
      '@@ -1,${kFileEditMaxLines * 2} +1,${kFileEditMaxLines * 2} @@',
      for (var i = 0; i < kFileEditMaxLines * 2; i++) '+line $i',
    ].join('\n');
    await pump(
      tester,
      FileEditRecord(
        path: '/repo/big.txt',
        kind: FileEditKind.modified,
        recordedDiff: patch,
      ),
    );
    await tester.tap(find.text('big.txt'));
    await tester.pumpAndSettle();

    expect(find.textContaining('first $kFileEditMaxLines'), findsOneWidget);
  });

  testWidgets('every changed line is labelled for a screen reader', (
    tester,
  ) async {
    // Disposed inside the body, not in a tearDown: the framework checks for
    // live handles before tearDowns run.
    final handle = tester.ensureSemantics();

    await pump(tester, _modified);
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();

    // Colour carries the same meaning for sighted users; neither the `+`/`-`
    // prefix nor these labels may be the only channel.
    expect(find.bySemanticsLabel('Added line'), findsOneWidget);
    expect(find.bySemanticsLabel('Removed line'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Modified.*a.dart')),
      findsAtLeastNWidgets(1),
    );

    handle.dispose();
  });

  testWidgets('fits a phone-sized pane and a desktop one', (tester) async {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      // A fresh key per size, so the second pump gets a collapsed card rather
      // than reusing the first one's expanded State and toggling it shut.
      await pump(tester, _modified, size: size, key: ValueKey(size));
      await tester.tap(find.text('a.dart'));
      await tester.pumpAndSettle();
      // A layout overflow fails the pump on its own; this asserts the content
      // survived the narrow pane rather than being clipped away.
      expect(find.text('+TWO'), findsOneWidget, reason: 'at $size');
      expect(find.text('Modified'), findsOneWidget, reason: 'at $size');
    }
  });

  testWidgets('a rebuild does not re-diff', (tester) async {
    await pump(tester, _modified);
    final after = fileEditDiffComputations;
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    expect(fileEditDiffComputations, after);
  });
}
