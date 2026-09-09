import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala/src/features/repositories/domain/discovered_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeRepositoryDiscoveryService discovery;

  EnvironmentPath root(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    discovery = FakeRepositoryDiscoveryService(
      result: [DiscoveredRepository(name: 'app', path: root(r'C:\ws\app'))],
    );
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // Every session card asks git what its checkout has changed. A
          // widget test must never spawn `git`, so the runner is a fake and
          // the cards render the "nothing changed" answer.
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows an empty state initially', (tester) async {
    await pump(tester);
    expect(find.textContaining('No projects yet'), findsOneWidget);
  });

  testWidgets('creating a project via the dialog adds it to the tree', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byTooltip('New project'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Folder path').first,
      r'C:\ws',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project name').first,
      'Workspace',
    );
    await tester.tap(find.text('Create & scan'));
    await tester.pumpAndSettle();

    expect(find.text('Workspace'), findsOneWidget);
    expect(discovery.calls, isNotEmpty);
  });
}
