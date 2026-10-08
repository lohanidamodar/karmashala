import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/widgets/status_strip.dart';

/// **A session's one status line** (round 59): labels shorten before
/// anything folds, what folds goes whole into +N, whose sheet lists every
/// item, and the pinned items never fold.
void main() {
  StatusStripItem item(String id, double full, double short) => StatusStripItem(
    id: id,
    builder: (_, isShort) => SizedBox(
      width: isShort ? short : full,
      height: 20,
      child: Text(isShort ? 'short:$id' : 'full:$id'),
    ),
  );

  final pinned = [item('state', 60, 60), item('model', 120, 70)];
  final items = [
    item('permission', 140, 60),
    item('agent', 100, 100),
    item('branch', 100, 100),
    item('machine', 100, 100),
    // Says nothing: never counted, never folded.
    StatusStripItem(id: 'quiet', builder: (_, _) => const SizedBox.shrink()),
  ];

  Future<void> pump(
    WidgetTester tester,
    double width, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: StatusStrip(
              pinned: pinned,
              items: items,
              sheetTitle: 'Session',
              more: IconButton(
                key: const ValueKey('more'),
                onPressed: () {},
                icon: const Icon(Icons.more_horiz),
              ),
              sheetFooter: (_) => const Text('the verbs'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// The items drawn on the line: a folded one is neither painted nor hit.
  List<String> onLine(WidgetTester tester) {
    return [
      for (final id in [
        'state',
        'model',
        'permission',
        'agent',
        'branch',
        'machine',
      ])
        if (find
            .byKey(ValueKey('status-strip:$id'))
            .hitTestable()
            .evaluate()
            .isNotEmpty)
          id,
    ];
  }

  testWidgets('wide: every item whole, in order, and ⋯ at the end', (
    tester,
  ) async {
    await pump(tester, 1100);
    expect(tester.takeException(), isNull);
    expect(onLine(tester), [
      'state',
      'model',
      'permission',
      'agent',
      'branch',
      'machine',
    ]);
    expect(find.text('full:model'), findsOneWidget);
    expect(find.byKey(StatusStrip.foldKey), findsNothing);
    expect(find.byKey(const ValueKey('more')), findsOneWidget);
  });

  testWidgets('labels shorten before anything folds', (tester) async {
    // Under the 720px breakpoint, and room for everything short.
    await pump(tester, 700);
    expect(find.text('short:model'), findsOneWidget);
    expect(find.text('short:permission'), findsOneWidget);
    expect(find.byKey(StatusStrip.foldKey), findsNothing);
  });

  for (final (width, folded) in const [(360.0, 2), (412.0, 2), (500.0, 1)]) {
    testWidgets('at ${width.round()} px the last $folded fold into +$folded', (
      tester,
    ) async {
      await pump(tester, width);
      expect(tester.takeException(), isNull);
      expect(find.text('+$folded'), findsOneWidget);
      expect(find.byKey(const ValueKey('more')), findsNothing);
      final line = onLine(tester);
      // The pinned items never fold; the quiet one is never counted.
      expect(line.take(2), ['state', 'model']);
      expect(line, hasLength(6 - folded));
    });
  }

  testWidgets('at text 1.6 the labels shorten at a wider width', (
    tester,
  ) async {
    await pump(tester, 1100);
    expect(find.text('full:model'), findsOneWidget);
    await pump(tester, 1100, textScale: 1.6);
    expect(find.text('short:model'), findsOneWidget);
  });

  testWidgets('+N opens a sheet listing every item whole, then the verbs', (
    tester,
  ) async {
    await pump(tester, 360);
    await tester.tap(find.byKey(StatusStrip.foldKey));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('status-strip-sheet'));
    for (final id in [
      'state',
      'model',
      'permission',
      'agent',
      'branch',
      'machine',
    ]) {
      expect(
        find.descendant(of: sheet, matching: find.text('full:$id')),
        findsOneWidget,
        reason: id,
      );
    }
    expect(
      find.descendant(of: sheet, matching: find.text('the verbs')),
      findsOneWidget,
    );
  });
}
