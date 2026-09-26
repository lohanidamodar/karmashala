import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/presentation/detected_projects_view.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

class _NoStores implements CliDetectionService {
  const _NoStores();
  @override
  Future<List<DetectedProject>> detect(
    List<CliStore> stores,
    Map<String, ExecutionEnvironment> environmentsById,
  ) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Detect CLI sessions opens the shared, shared-size dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final data =
        await (FakeDataServer()
              ..environmentRows.upsert(localHostEnvironment(testTime)))
            .override();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          data,
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
          cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
          cliDetectionServiceProvider.overrideWithValue(const _NoStores()),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Detect CLI sessions'));
    await tester.pumpAndSettle();

    // One size for every way in, so the Explorer and the app menu agree.
    final box = tester.widget<ConstrainedBox>(
      find
          .ancestor(
            of: find.byType(DetectedProjectsView),
            matching: find.byType(ConstrainedBox),
          )
          .first,
    );
    expect(box.constraints.maxWidth, DetectedProjectsView.dialogMaxSize.width);
    expect(
      box.constraints.maxHeight,
      DetectedProjectsView.dialogMaxSize.height,
    );
  });
}
