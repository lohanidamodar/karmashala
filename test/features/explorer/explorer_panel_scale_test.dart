import 'package:karmashala/src/core/database/app_database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// What the Explorer costs as a workspace grows.
///
/// The owner's own database is 7 native sessions and 107 imported ones, and the
/// terminal is still laggy with every terminal-side fix in — so the question
/// this file exists to answer is whether the panel that shares the frame with
/// the terminal costs O(rows) or O(visible rows) per rebuild.
///
/// It reports a **curve**, not a wall-clock number: the absolute milliseconds
/// on a CI machine mean nothing, and the shape is the whole finding. The
/// assertion is the deterministic half of that shape — how many session cards
/// are actually *inflated* — because a timing threshold on a shared machine is
/// a flaky test, and the count is what "virtualised" means.
///
/// What it found (2026-08-31, debug VM): 10/100/500 sessions all inflate the
/// same handful of cards, and a panel rebuild costs the same at 500 as at 10.
/// `ListView(children: …)` already builds only what the sliver asks for, so the
/// cost is O(*visible* cards) with a large constant — roughly 1–2 ms per
/// visible card in debug — and not O(rows). Collapsing the project (no cards)
/// costs a third of the same rebuild, which is where that split comes from.
void main() {
  late AppDatabase db;
  late FakeCommandRunner git;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(
      db,
    ).insert(repository(id: 'r1', name: 'hub', path: r'C:\hub'));
    AgentInstallationDao(db).insert(agentInstallation());
    git = FakeCommandRunner(responder: _git);
  });
  tearDown(() => db.close());

  /// The owner's shape: a handful of native sessions and a long tail of
  /// imported CLI history, all on one repository.
  void seed(int count) {
    final natives = count ~/ 16 + 1;
    for (var i = 0; i < natives; i++) {
      SessionDao(db).insert(
        Session(
          id: 'n$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Native $i',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime.add(Duration(minutes: i)),
          externalSessionId: 'native-ext-$i',
        ),
      );
    }
    for (var i = natives; i < count; i++) {
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 'i$i',
          repositoryId: 'r1',
          cli: 'claudeCode',
          externalId: 'imported-ext-$i',
          environmentId: 'windows',
          filePath:
              r'C:\store\'
              'imported-ext-$i.jsonl',
          storeHome: r'C:\store',
          isSubagent: false,
          preview: 'Imported $i',
          title: 'Imported $i',
          updatedAt: testTime.add(Duration(minutes: i)),
          createdAt: testTime,
        ),
      );
    }
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool expand = true,
  }) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    if (expand) {
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();
    }
    return container;
  }

  Future<int> timePumps(
    WidgetTester tester,
    ProviderContainer container, {
    required bool invalidate,
    int times = 20,
  }) async {
    final watch = Stopwatch()..start();
    for (var i = 0; i < times; i++) {
      if (invalidate) container.read(sessionsRevisionProvider.notifier).bump();
      await tester.pump();
    }
    watch.stop();
    return watch.elapsedMicroseconds ~/ times;
  }

  /// What one panel rebuild costs, against the floor of a frame that rebuilds
  /// nothing, and how many session cards were actually inflated.
  Future<({int rebuild, int idle, int cards})> measure(
    WidgetTester tester,
    int count, {
    bool expand = true,
  }) async {
    seed(count);
    final container = await pump(tester, expand: expand);
    final cards = tester.widgetList(find.byType(SessionCard)).length;

    // Warm up: the first rebuild after a seed pays for provider creation.
    container.read(sessionsRevisionProvider.notifier).bump();
    await tester.pump();

    final idle = await timePumps(tester, container, invalidate: false);
    final rebuild = await timePumps(tester, container, invalidate: true);
    return (rebuild: rebuild, idle: idle, cards: cards);
  }

  for (final count in [10, 100, 500]) {
    testWidgets('$count sessions', (tester) async {
      final result = await measure(tester, count);
      // ignore: avoid_print
      print(
        'EXPLORER-SCALE sessions=$count '
        'rebuild_us=${result.rebuild} idle_us=${result.idle} '
        'net_us=${result.rebuild - result.idle} '
        'cards_inflated=${result.cards}',
      );
      // The invariant: what a screenful holds, whatever the workspace holds.
      // 460x900 fits well under thirty rows; the bound is generous so a theme
      // or density change is not a failing test.
      expect(result.cards, lessThanOrEqualTo(32));
    });

    testWidgets('\$count sessions, collapsed', (tester) async {
      final result = await measure(tester, count, expand: false);
      // ignore: avoid_print
      print(
        'EXPLORER-SCALE-COLLAPSED sessions=$count '
        'rebuild_us=${result.rebuild} idle_us=${result.idle} '
        'net_us=${result.rebuild - result.idle} '
        'cards_inflated=${result.cards}',
      );
      expect(result.cards, 0);
    });
  }
}

CommandResult _git(CommandRequest request) =>
    CommandResult(exitCode: 0, stdout: '', stderr: '');
