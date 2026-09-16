import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/presentation/detected_projects_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late List<int> scans;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    scans = [];
  });
  tearDown(() => db.close());

  /// The title bar alone over an empty body, with detection counted rather
  /// than run: a scan reads the real CLI stores.
  Widget titleBar() => ProviderScope(
    overrides: [
      ...fakeTerminalOverrides(database: db),
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

    await tester.tap(find.text('Workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect CLI sessions'));
    await tester.pumpAndSettle();

    expect(scans, hasLength(1));
    final size = tester.getSize(find.byType(DetectedProjectsView));
    expect(size.width, lessThanOrEqualTo(DetectedProjectsView.dialogMaxSize.width));
    expect(
      size.height,
      lessThanOrEqualTo(DetectedProjectsView.dialogMaxSize.height),
    );
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
