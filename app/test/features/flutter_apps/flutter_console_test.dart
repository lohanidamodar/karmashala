import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/flutter_apps/application/attached_apps.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_app_pane.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_console_toolbar.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fakes.dart';
import 'fake_vm_service.dart';

void main() {
  late Directory temp;
  late FakeVmService fake;
  const uri = 'ws://127.0.0.1:1/a=/ws';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('karmashala-flutter-console');
    File(
      '${temp.path}${Platform.pathSeparator}windows.uri',
    ).writeAsStringSync(uri);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer() {
    // Built inside the test body: its streams must run in the test zone.
    fake = FakeVmService(selectedWidget: null);
    final container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 9, 8))),
        flutterAppDiscoveryDirectoryProvider.overrideWith(
          (ref) async => VmServiceUriDirectory(temp),
        ),
        dtdPidFilesProvider.overrideWithValue(const DtdPidFiles(<String>[])),
        adbServiceProvider.overrideWithValue(null),
        devicesProvider.overrideWith((ref) async => const []),
        vmServiceConnectorProvider.overrideWithValue((u) async {
          if (u.toString() != uri) throw StateError('refused');
          return fake.client;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    ProviderContainer? container,
    Size size = const Size(900, 700),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final scope = container ?? makeContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: const MaterialApp(home: Scaffold(body: FlutterAppPane())),
      ),
    );
    await tester.pumpAndSettle();
    return scope;
  }

  Future<void> say(WidgetTester tester, List<String> lines) async {
    for (final line in lines) {
      fake.emitStdout('$line\n');
    }
    await tester.pumpAndSettle();
  }

  Finder field() => find.byType(TextField);

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pumpAndSettle();
  }

  testWidgets('typing highlights and counts; only-matching hides the rest', (
    tester,
  ) async {
    await pump(tester);
    await say(tester, ['alpha boom', 'beta', 'gamma BOOM']);

    await search(tester, 'boom');
    expect(find.text('2 matches'), findsOneWidget);
    // Highlighting never hides.
    expect(find.text('beta'), findsOneWidget);

    await tester.tap(find.byTooltip('Show only matching lines'));
    await tester.pumpAndSettle();
    expect(find.text('beta'), findsNothing);
    expect(find.text('alpha boom'), findsOneWidget);
    expect(find.textContaining('2 of '), findsOneWidget);

    await tester.tap(find.byTooltip('Match case'));
    await tester.pumpAndSettle();
    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('gamma BOOM'), findsNothing);
  });

  testWidgets('an invalid regex says so inline and hides nothing', (
    tester,
  ) async {
    await pump(tester);
    await say(tester, ['one', 'two']);
    await tester.tap(find.byTooltip('Use regular expression'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show only matching lines'));
    await search(tester, '(unclosed');
    expect(tester.takeException(), isNull);
    expect(find.text('Invalid pattern'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
  });

  testWidgets('source chips count and filter; errors group stderr and '
      'framework errors', (tester) async {
    await pump(tester);
    await say(tester, ['out one', 'out two']);
    fake.emitStdout('bad\n', stderr: true);
    fake.emitFlutterError(flutterErrorTree());
    fake.emitDeveloperLog('net up', loggerName: 'net');
    fake.emitDeveloperLog('db ready', loggerName: 'db');
    await tester.pumpAndSettle();

    expect(find.text('Output 2'), findsOneWidget);
    expect(find.text('Errors 2'), findsOneWidget);
    expect(find.text('Logs 2'), findsOneWidget);

    await tester.tap(find.text('Errors 2'));
    await tester.pumpAndSettle();
    expect(find.text('out one'), findsNothing);
    expect(find.text('bad'), findsOneWidget);
    expect(find.textContaining('The following StateError'), findsWidgets);

    // Multi-select: add Logs, then narrow logs to one logger.
    await tester.tap(find.text('Logs 2'));
    await tester.pumpAndSettle();
    expect(find.text('net up'), findsOneWidget);
    await tester.tap(find.text('All loggers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('net 1').last);
    await tester.pumpAndSettle();
    expect(find.text('net up'), findsOneWidget);
    expect(find.text('db ready'), findsNothing);
    expect(find.text('bad'), findsOneWidget);
  });

  testWidgets('Enter and Shift+Enter step through matches, scrolling to and '
      'highlighting the current one', (tester) async {
    await pump(tester);
    await say(tester, [
      for (var i = 0; i < 200; i++) i % 50 == 0 ? 'needle $i' : 'hay $i',
    ]);
    await search(tester, 'needle');
    expect(find.text('4 matches'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('4 of 4'), findsOneWidget);

    // Wraps from the newest to the oldest, far above the fold.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('1 of 4'), findsOneWidget);
    expectCurrentVisible(tester, 'needle 0');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('4 of 4'), findsOneWidget);
    expectCurrentVisible(tester, 'needle 150');

    await tester.tap(find.byTooltip('Previous match (Shift+Enter)'));
    await tester.pumpAndSettle();
    expect(find.text('3 of 4'), findsOneWidget);
    expectCurrentVisible(tester, 'needle 100');
  });

  testWidgets('Ctrl+F focuses the search from inside the console; Esc clears, '
      'then leaves', (tester) async {
    await pump(tester);
    await say(tester, ['first line', 'second line']);

    await tester.tap(find.text('second line'));
    await tester.pumpAndSettle();
    final focus = tester.widget<TextField>(field()).focusNode!;
    expect(focus.hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);

    await tester.enterText(field(), 'first');
    await tester.pumpAndSettle();
    expect(find.text('1 match'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
    expect(find.text('1 match'), findsNothing);
    expect(focus.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
  });

  testWidgets('follows the newest line until scrolled up, then offers a jump', (
    tester,
  ) async {
    await pump(tester);
    await say(tester, [for (var i = 0; i < 120; i++) 'line $i']);
    await say(tester, ['line 120']);
    expect(find.text('line 120'), findsOneWidget);
    expect(find.textContaining('Jump to latest'), findsNothing);

    await tester.drag(find.text('line 110'), const Offset(0, 400));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('line 100'));

    await say(tester, ['line 121', 'line 122']);
    // Not moved by what arrived, and not showing it.
    expect(tester.getTopLeft(find.text('line 100')), before);
    expect(find.text('line 122'), findsNothing);
    expect(find.text('Jump to latest (2 new)'), findsOneWidget);

    await tester.tap(find.text('Jump to latest (2 new)'));
    await tester.pumpAndSettle();
    expect(find.text('line 122'), findsOneWidget);
    await say(tester, ['line 123']);
    expect(find.text('line 123'), findsOneWidget);
    expect(find.textContaining('Jump to latest'), findsNothing);
  });

  testWidgets('query and filters survive a remount', (tester) async {
    final container = await pump(tester);
    await say(tester, ['keep me', 'other']);
    fake.emitStdout('bad\n', stderr: true);
    await tester.pumpAndSettle();
    await search(tester, 'keep');
    await tester.tap(find.textContaining('Output '));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    await tester.pumpAndSettle();
    await pump(tester, container: container);

    expect(tester.widget<TextField>(field()).controller!.text, 'keep');
    expect(find.text('1 match'), findsOneWidget);
    final chip = tester.widget<FilterChip>(
      find.ancestor(
        of: find.textContaining('Output '),
        matching: find.byType(FilterChip),
      ),
    );
    expect(chip.selected, isTrue);
    expect(find.text('bad'), findsNothing);
  });

  testWidgets('a console line does not rebuild the toolbar', (tester) async {
    await pump(tester);
    await say(tester, ['first']);
    final builds = FlutterConsoleToolbar.debugBuilds;
    await say(tester, ['second', 'third']);
    expect(find.text('third'), findsOneWidget);
    expect(find.text('Output 3'), findsOneWidget);
    expect(FlutterConsoleToolbar.debugBuilds, builds);
  });

  testWidgets('clearing empties the view, not the app', (tester) async {
    final container = await pump(tester);
    await say(tester, ['old news']);
    await tester.tap(
      find.byTooltip('Clear the console (the app keeps running)'),
    );
    await tester.pumpAndSettle();
    expect(find.text('old news'), findsNothing);
    expect(find.text('Cleared. New lines will appear here.'), findsOneWidget);
    final link = container
        .read(attachedAppsProvider.notifier)
        .linkFor(container.read(attachedAppsProvider).apps.single.id)!;
    expect(link.console.map((r) => r.message), contains('old news'));

    await say(tester, ['fresh']);
    expect(find.text('fresh'), findsOneWidget);
  });

  testWidgets('a narrow panel folds chips and toggles into one menu', (
    tester,
  ) async {
    await pump(tester, size: const Size(240, 700));
    await say(tester, ['fine']);
    fake.emitStdout('bad\n', stderr: true);
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip), findsNothing);

    await tester.tap(find.byTooltip('Filters and search options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Errors 1'));
    await tester.pumpAndSettle();
    expect(find.text('fine'), findsNothing);
    expect(find.text('bad'), findsOneWidget);

    await search(tester, 'bad');
    // The count moves to the status row.
    expect(find.text('1 match'), findsOneWidget);
  });

  testWidgets('the filtered view is capped for rendering, and says so', (
    tester,
  ) async {
    await pump(tester);
    await say(tester, [for (var i = 0; i < 520; i++) 'row $i']);
    expect(
      find.textContaining('showing newest 500 of 521 lines'),
      findsOneWidget,
    );
  });
}

/// The current match is on screen and drawn on the current-match fill.
void expectCurrentVisible(WidgetTester tester, String text) {
  final line = find.text(text);
  expect(line, findsOneWidget, reason: '$text should be built');
  final list = tester.getRect(find.byType(ListView));
  final rect = tester.getRect(line);
  expect(
    list.contains(rect.center),
    isTrue,
    reason: '$text at $rect should be inside $list',
  );
  final context = tester.element(line);
  final scheme = Theme.of(context).colorScheme;
  final selectable = tester.widget<SelectableText>(
    find.ancestor(of: line, matching: find.byType(SelectableText)),
  );
  final spans = <InlineSpan>[];
  selectable.textSpan!.visitChildren((span) {
    spans.add(span);
    return true;
  });
  expect(
    spans.any(
      (span) =>
          span.style?.backgroundColor == StateLayers.textSelection(scheme),
    ),
    isTrue,
  );
}
