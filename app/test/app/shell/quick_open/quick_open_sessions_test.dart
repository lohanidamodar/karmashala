/// **Quick Open's session list: ordered by last activity, and it says so.**
///
/// It used to sort by `updatedAt ?? createdAt` and draw no time at all, because
/// the age it wanted cost a transcript stat per session and this list rebuilds
/// on every keystroke. The status registry already holds that reading, so both
/// halves are now free: the palette orders by the same value the sidebar and
/// the phone do, and prints it beside the row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';
import '../../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../../support/workspace_mirror.dart';

void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late Override data;

  /// "Now" for the rendered ages, and the instant every reading below is
  /// measured back from. Fixed, because an age drawn from a real clock is a
  /// test that fails at midnight.
  final now = DateTime.utc(2026, 8, 31, 12);

  /// The status registry's cached report per session id — the reading the
  /// production `sessionLastActiveProvider` reads. Overriding here rather than
  /// the last-active provider itself keeps the real rule under test.
  final reports = <String, AgentStatusReport>{};

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.override();
    reports.clear();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
  });
  tearDown(() => db.close());

  void active(String sessionId, Duration ago) {
    reports[sessionId] = AgentStatusReport(
      agentId: AgentIds.claudeCode,
      sessionId: sessionId,
      status: AgentActivityStatus.working,
      // A transcript, dated by the file rather than by the moment we read it.
      source: AgentStatusSource.stateFile,
      observedAt: now,
      sourceModifiedAt: now.subtract(ago),
    );
  }

  void session(
    String id, {
    required String title,
    Duration createdAgo = Duration.zero,
  }) => SessionDao(db).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: title,
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: now.subtract(createdAgo),
    ),
  );

  Future<ProviderContainer> open(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(now)),
        sessionStatusLookupProvider.overrideWithValue((id) => reports[id]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  /// The order the palette actually offers, top to bottom. A title with a
  /// fuzzy hit in it is a `Text.rich`, so the spans are flattened rather than
  /// the row being missed.
  List<String> listed(WidgetTester tester) => [
    for (final text in tester.widgetList<Text>(find.byType(Text)))
      ?(text.data ?? text.textSpan?.toPlainText()),
  ];

  testWidgets('the row says when the session was last active', (tester) async {
    session('s1', title: 'Rebuild the index');
    active('s1', const Duration(minutes: 3));
    await open(tester);

    await type(tester, 'Rebuild');

    expect(find.textContaining('active 3m ago'), findsOneWidget);
  });

  testWidgets('and a day-old reading is worded the same way', (tester) async {
    session('s1', title: 'Rebuild the index');
    active('s1', const Duration(days: 2));
    await open(tester);

    await type(tester, 'Rebuild');

    expect(find.textContaining('active 2d ago'), findsOneWidget);
  });

  testWidgets('a session we hold no reading for is given no age', (
    tester,
  ) async {
    session('s1', title: 'Rebuild the index');
    await open(tester);

    await type(tester, 'Rebuild');

    // §19: no reading is not a zero one, and "just now" for a session nothing
    // has been observed of is the confident false statement the rule refuses.
    expect(find.text('Rebuild the index'), findsOneWidget);
    expect(find.textContaining('active '), findsNothing);
  });

  testWidgets('the most recently active session is offered first', (
    tester,
  ) async {
    // Deliberately crossed: the session created most recently is the one that
    // has been silent, which is the report — "the sessions were supposed to be
    // ordered by last active time".
    session(
      'quiet',
      title: 'Match quiet',
      createdAgo: const Duration(hours: 1),
    );
    session('busy', title: 'Match busy', createdAgo: const Duration(days: 30));
    active('quiet', const Duration(hours: 20));
    active('busy', const Duration(minutes: 1));
    await open(tester);

    await type(tester, 'Match');

    final rows = listed(tester);
    expect(
      rows.indexOf('Match busy'),
      lessThan(rows.indexOf('Match quiet')),
      reason: 'recency is a rank over last activity, not over creation',
    );
  });

  testWidgets('a session with no reading ranks below every one that has '
      'some', (tester) async {
    session('silent', title: 'Match silent', createdAgo: Duration.zero);
    session(
      'ancient',
      title: 'Match ancient',
      createdAgo: const Duration(days: 90),
    );
    active('ancient', const Duration(days: 60));
    await open(tester);

    await type(tester, 'Match');

    final rows = listed(tester);
    expect(
      rows.indexOf('Match ancient'),
      lessThan(rows.indexOf('Match silent')),
    );
  });

  testWidgets('imported history is dated by its own file', (tester) async {
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i1',
        repositoryId: 'r1',
        cli: AgentIds.claudeCode,
        externalId: 'conv-9',
        environmentId: 'windows',
        filePath: r'C:\store\conv-9.jsonl',
        storeHome: r'C:\store',
        isSubagent: false,
        preview: 'preview',
        title: 'Match imported',
        createdAt: now.subtract(const Duration(days: 4)),
        updatedAt: now.subtract(const Duration(hours: 5)),
      ),
    );
    await open(tester);

    await type(tester, 'Match');

    expect(find.textContaining('active 5h ago'), findsOneWidget);
  });
}
