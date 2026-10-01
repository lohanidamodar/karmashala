import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/presentation/detected_projects_view.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/shell_menu.dart';
import '../../support/window_matrix.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late List<int> scans;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
    scans = [];
  });

  /// The title bar alone over an empty body, with detection counted rather
  /// than run: a scan reads the real CLI stores.
  Widget titleBar() => ProviderScope(
    overrides: [
      ...fakeTerminalOverrides(machine: db, data: data),
      detectedProjectsControllerProvider.overrideWith(
        () => _CountingDetection(scans),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: ShellTitleBar(height: Chrome.titleBarOf(context)),
          body: const SizedBox.expand(),
        ),
      ),
    ),
  );

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(titleBar());
    await tester.pumpAndSettle();
  }

  testWidgets('Detect CLI sessions opens the shared, bounded view', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1440, 900));

    await openShellMenu(tester, 'Workspace');
    await tester.tap(find.text('Detect CLI sessions'));
    await tester.pumpAndSettle();

    expect(scans, hasLength(1));
    final size = tester.getSize(find.byType(DetectedProjectsView));
    expect(
      size.width,
      lessThanOrEqualTo(DetectedProjectsView.dialogMaxSize.width),
    );
    expect(
      size.height,
      lessThanOrEqualTo(DetectedProjectsView.dialogMaxSize.height),
    );
  });

  testWidgets(
    'the title bar survives narrow, large-text and very wide windows',
    (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: titleBar,
        matrix: const [
          // The compact pane selector's window at the largest text step: the
          // menu titles alone took 487 of its 640px and the row ran 23px over.
          WindowCell('640x900 @ 2x text', Size(640, 900), textScale: 2),
          minimumWindowLargeText,
          WindowCell('720x560 @ 2x text', Size(720, 560), textScale: 2),
          WindowCell('1000x700 @ 2x text', Size(1000, 700), textScale: 2),
          desktopWindow,
          WindowCell('3840x1200 (very wide)', Size(3840, 1200)),
        ],
      );
    },
  );

  testWidgets('a row too narrow for the menu titles folds them behind one '
      'glyph, and every item is still reachable', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpAt(tester, const Size(640, 900));

    expect(find.byType(MenuBar), findsNothing);
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect CLI sessions'));
    await tester.pumpAndSettle();

    // The item's own context is gone once the menu closes; the scan and the
    // dialog must still happen.
    expect(scans, hasLength(1));
    expect(find.byType(DetectedProjectsView), findsOneWidget);
  });

  // The board's title bar: one menu glyph at every width, never a row of
  // menu titles (b2063bc4d).
  testWidgets('a row with room still has the one menu glyph, not titles', (
    tester,
  ) async {
    for (final (size, scale) in [
      (const Size(1440, 900), 1.0),
      (const Size(720, 560), 1.0),
      (const Size(720, 560), 1.3),
      (const Size(1440, 900), 2.0),
    ]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await pumpAt(tester, size);
      expect(find.byType(MenuBar), findsNothing, reason: '$size @ $scale');
      expect(find.byTooltip('Menu'), findsOneWidget, reason: '$size @ $scale');
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

class _CountingDetection extends DetectedProjectsController {
  _CountingDetection(this._scans);

  final List<int> _scans;

  @override
  Future<List<DetectedProject>> build() async => const [];

  @override
  Future<void> detect() async => _scans.add(_scans.length);
}
