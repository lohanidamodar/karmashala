import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/paths/path_probe.dart';
import 'package:karmashala/src/core/paths/path_probe_provider.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_path_repair_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_path_repair.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/presentation/agent_path_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_path_probe.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

const _stored = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe';
const _claude = r'C:\Users\d\.local\bin\claude.exe';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<void> pumpSection(
    WidgetTester tester, {
    AgentPathRepairReport report = const AgentPathRepairReport.unchecked(),
    Size size = const Size(1440, 900),
    DateTime? now,
  }) async {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        pathProbeProvider.overrideWithValue(FakePathProbe()),
        clockProvider.overrideWithValue(FixedClock(now ?? testTime)),
      ],
    );
    container.read(agentPathRepairProvider.notifier).set(report);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AgentPathSection()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AgentPathReading readingFor(String path, ExecutableReachability level) =>
      AgentPathReading(
        installation: AgentInstallationDao(db).getAll().single,
        displayName: 'Codex CLI',
        reading: ExecutableReading(path: path, reachability: level),
      );

  testWidgets('says nothing has been checked before a check runs', (t) async {
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.codex, path: _stored),
    );
    await pumpSection(t);

    // §19: an unobserved state is not a healthy one.
    expect(find.textContaining('have not been checked yet'), findsOneWidget);
  });

  testWidgets('an unreachable path reads differently from a missing one', (
    t,
  ) async {
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.codex, path: _stored),
    );
    await pumpSection(
      t,
      report: AgentPathRepairReport(
        checkedAt: testTime,
        broken: [readingFor(_stored, ExecutableReachability.unreachable)],
        unresolved: [readingFor(_stored, ExecutableReachability.unreachable)],
      ),
    );

    // The distinction the feature exists for: this row must not say the CLI
    // is absent, because the fix is a different path rather than an install.
    expect(find.textContaining('cannot be reached'), findsWidgets);
    expect(find.textContaining('Install the CLI'), findsNothing);
  });

  testWidgets('a missing path says to install it or set the path', (t) async {
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.codex, path: _stored),
    );
    await pumpSection(
      t,
      report: AgentPathRepairReport(
        checkedAt: testTime,
        broken: [readingFor(_stored, ExecutableReachability.missing)],
        unresolved: [readingFor(_stored, ExecutableReachability.missing)],
      ),
    );

    expect(find.textContaining('Nothing opens at this path'), findsOneWidget);
  });

  testWidgets('each row says whether it was detected or set by hand', (
    t,
  ) async {
    final dao = AgentInstallationDao(db)
      ..insert(
        agentInstallation(
          id: 'auto',
          agentId: AgentIds.codex,
          path: r'C:\auto\codex.exe',
        ),
      )
      ..insert(
        agentInstallation(
          id: 'mine',
          agentId: AgentIds.claudeCode,
          path: r'C:\mine\claude.exe',
        ),
      );
    dao.updatePath('mine', r'C:\mine\claude.exe', byUser: true);
    await pumpSection(t);

    // Without this the user cannot tell why a repair did or did not touch a
    // row, which makes the pinning rule look like a bug.
    expect(find.text('auto-detected'), findsOneWidget);
    expect(find.text('set by you'), findsOneWidget);
  });

  testWidgets('typing a path stores it, marked as the user\'s choice', (
    t,
  ) async {
    AgentInstallationDao(db).insert(
      agentInstallation(
        id: 'codex-row',
        agentId: AgentIds.codex,
        path: _stored,
      ),
    );
    await pumpSection(t);

    await t.enterText(find.byType(TextField), r'C:\chosen\codex.exe');
    await t.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await t.pump();

    final row = AgentInstallationDao(db).getById('codex-row')!;
    expect(row.executable.path, r'C:\chosen\codex.exe');
    expect(row.executableByUser, isTrue);
    expect(find.text('set by you'), findsOneWidget);
  });

  testWidgets('a path another row already holds is refused, visibly', (
    t,
  ) async {
    AgentInstallationDao(db)
      ..insert(
        agentInstallation(
          id: 'a',
          agentId: AgentIds.codex,
          path: r'C:\a\codex.exe',
        ),
      )
      ..insert(
        agentInstallation(
          id: 'b',
          agentId: AgentIds.codex,
          path: r'C:\b\codex.exe',
        ),
      );
    await pumpSection(t);

    await t.enterText(find.byType(TextField).last, r'C:\a\codex.exe');
    await t.tap(find.widgetWithText(OutlinedButton, 'Save').last);
    await t.pump();

    // Silence would look like a save. The table forbids it, so the field says
    // so and the row keeps the path it had.
    expect(find.textContaining('already uses that path'), findsOneWidget);
    expect(
      AgentInstallationDao(db).getById('b')!.executable.path,
      r'C:\b\codex.exe',
    );
  });

  testWidgets('the field and its buttons fit a phone width', (t) async {
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.codex, path: _stored),
    );
    await pumpSection(t, size: const Size(390, 844));

    expect(t.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Browse'), findsOneWidget);
  });

  group('the version beside a path is a reading, and shows its age', () {
    testWidgets('a fresh reading renders the number with how old it is', (
      t,
    ) async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          agentId: AgentIds.codex,
          path: _stored,
          version: '0.153.4',
          versionReadAt: testTime,
        ),
      );

      await pumpSection(t, now: testTime.add(const Duration(minutes: 5)));

      expect(find.textContaining('0.153.4 · read 5m ago'), findsOneWidget);
    });

    testWidgets('a reading past the bound says it may be out of date', (
      t,
    ) async {
      // The owner's row. A bare "2.1.252" beside a binary answering 2.1.263 is
      // a confident false statement; the same number wearing its age is not.
      AgentInstallationDao(db).insert(
        agentInstallation(path: _claude, version: '2.1.252', versionReadAt: testTime),
      );

      await pumpSection(t, now: testTime.add(const Duration(days: 2)));

      expect(
        find.textContaining('2.1.252 · last read 2d ago, may be out of date'),
        findsOneWidget,
      );
    });

    testWidgets('a number nobody dated says that, rather than nothing', (
      t,
    ) async {
      // Every row written before v40, including the one whose binary is gone:
      // its version is kept and its age is admitted to be unknown.
      AgentInstallationDao(db).insert(
        agentInstallation(path: _claude, version: '2.1.245'),
      );

      await pumpSection(t);

      expect(
        find.textContaining('2.1.245 · read at an unknown time'),
        findsOneWidget,
      );
    });

    testWidgets('a row with no version at all claims nothing', (t) async {
      AgentInstallationDao(db).insert(
        agentInstallation(agentId: AgentIds.codex, path: _stored, version: null),
      );

      await pumpSection(t);

      expect(find.textContaining('read'), findsNothing);
    });
  });
}
