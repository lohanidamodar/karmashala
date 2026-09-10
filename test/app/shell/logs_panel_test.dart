import 'package:karmashala/src/app/shell/logs_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/logging/diagnostics_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  late Diagnostics diagnostics;
  late Diagnostics previous;

  setUp(() {
    previous = Diagnostics.instance;
    diagnostics = Diagnostics(
      buffer: LogRingBuffer(capacity: 5000),
      echoToConsole: false,
    );
    Diagnostics.instance = diagnostics;
    AppLogger.initialize(level: Level.ALL);
  });
  tearDown(() {
    Diagnostics.instance = previous;
    Logger.root.level = Level.INFO;
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [diagnosticsProvider.overrideWithValue(diagnostics)],
        child: const MaterialApp(home: Scaffold(body: LogsPanel())),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows the tail that was recorded before it was opened', (
    tester,
  ) async {
    // The whole point of always-on capture: nobody should have to reproduce a
    // failure to see it.
    AppLogger.named('remote').warning('pairing timed out');
    await pumpPanel(tester);

    expect(find.textContaining('pairing timed out'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('new records appear on the refresh tick, not per record', (
    tester,
  ) async {
    await pumpPanel(tester);
    AppLogger.named('sessions').info('created session s-1');
    await tester.pump(LogsPanel.refreshInterval);

    expect(find.textContaining('created session s-1'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('a flood repaints on the clock, not once per record', (
    tester,
  ) async {
    await pumpPanel(tester);
    final logger = AppLogger.named('device-stream');
    LogsPanel.debugBuildCount = 0;

    // 20,000 records in one synchronous burst — far faster than the frame
    // budget, and exactly what `device-stream` does.
    for (var i = 0; i < 20000; i++) {
      logger.info('frame $i');
    }
    // Nothing has repainted yet: the buffer notifies nobody.
    expect(LogsPanel.debugBuildCount, 0);

    await tester.pump(LogsPanel.refreshInterval);
    await tester.pump(LogsPanel.refreshInterval);
    await tester.pump(LogsPanel.refreshInterval);

    expect(
      LogsPanel.debugBuildCount,
      lessThanOrEqualTo(4),
      reason: 'the tail must repaint on its timer, not per record',
    );
    expect(find.textContaining('frame 19999'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('filters by level, by channel and by text', (tester) async {
    AppLogger.named('remote').warning('pairing timed out');
    AppLogger.named('sessions').info('created session s-1');
    await pumpPanel(tester);

    await tester.tap(find.text('All levels'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Warnings and up').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('pairing timed out'), findsOneWidget);
    expect(find.textContaining('created session s-1'), findsNothing);

    await tester.tap(find.text('Warnings and up').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All levels').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'session');
    await tester.pump();
    expect(find.textContaining('created session s-1'), findsOneWidget);
    expect(find.textContaining('pairing timed out'), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('pausing freezes the tail; following picks it up again', (
    tester,
  ) async {
    AppLogger.named('remote').info('before the pause');
    await pumpPanel(tester);

    await tester.tap(find.byTooltip('Following  ·  click to pause'));
    await tester.pump();
    AppLogger.named('remote').info('while paused');
    await tester.pump(LogsPanel.refreshInterval);
    await tester.pump(LogsPanel.refreshInterval);

    expect(find.textContaining('while paused'), findsNothing);
    expect(find.textContaining('before the pause'), findsOneWidget);

    await tester.tap(
      find.byTooltip('Paused  ·  click to follow the newest lines'),
    );
    await tester.pump(LogsPanel.refreshInterval);
    expect(find.textContaining('while paused'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('copy puts the shown lines on the clipboard, redacted', (
    tester,
  ) async {
    const token = 'sk-ant-api03-Zx9Qw8Lm2Nv4Bt7Rk1Cy6Hd0Sf3Jg5Pu-AA';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    AppLogger.named('claude-auth').warning('refresh failed for $token');
    await pumpPanel(tester);
    await tester.tap(find.byTooltip('Copy the lines shown'));
    await tester.pump();

    expect(copied, isNotNull);
    expect(copied, isNot(contains(token)));
    expect(copied, contains('[redacted:token]'));
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('clearing empties the tail', (tester) async {
    AppLogger.named('remote').info('something');
    await pumpPanel(tester);
    await tester.tap(find.byTooltip('Clear the buffer'));
    await tester.pump();

    expect(find.textContaining('something'), findsNothing);
    expect(find.text('Nothing has been logged yet.'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('the filter pickers are sized like the panel around them', (
    tester,
  ) async {
    // `DropdownButton` is Material 2 and ignores the app's
    // `dropdownMenuTheme`, which only reaches Material 3's `DropdownMenu`. The
    // text style was already the panel's; the chevron was not, and drew at
    // Material's 24 beside a toolbar of `Chrome.icon` glyphs one row above.
    await pumpPanel(tester);
    final level = tester.widget<DropdownButton<Level>>(
      find.byType(DropdownButton<Level>),
    );
    final channel = tester.widget<DropdownButton<String?>>(
      find.byType(DropdownButton<String?>),
    );
    final theme = Theme.of(
      tester.element(find.byType(DropdownButton<Level>)),
    );
    expect(level.iconSize, Chrome.icon);
    expect(channel.iconSize, Chrome.icon);
    expect(level.style, theme.textTheme.labelSmall);
    expect(channel.style, theme.textTheme.labelSmall);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('the panel footer is a status bar of the window\'s height', (
    tester,
  ) async {
    // It was a bare 22 — the same number `Chrome.statusBar` names, but a
    // widget deciding a chrome height for itself.
    await pumpPanel(tester);
    final footer = tester.widget<Container>(
      find
          .ancestor(
            of: find.textContaining('shown'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(footer.constraints?.maxHeight, Chrome.statusBar);
    await tester.pump(const Duration(milliseconds: 200));
  });

  test('the surface is hidden unless debug mode is on', () {
    expect(
      SidePanelSurface.offered(debugMode: false),
      isNot(contains(SidePanelSurface.logs)),
    );
    expect(
      SidePanelSurface.offered(debugMode: true),
      contains(SidePanelSurface.logs),
    );
    // And nothing else moved.
    expect(SidePanelSurface.offered(debugMode: true), SidePanelSurface.values);
  });
}
