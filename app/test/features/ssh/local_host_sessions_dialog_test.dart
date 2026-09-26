import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/ssh/presentation/host_sessions_dialog.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// This computer's host, holding what a test puts in it.
class _LocalHost extends LocalHostSessionAccess {
  _LocalHost(this.sessions)
    : super(paths: HostPaths(Directory.systemTemp.createTempSync('ks-local')));

  final List<SessionSummary> sessions;
  final ended = <String>[];

  @override
  Future<List<SessionSummary>> listSessions() async => [
    for (final s in sessions)
      if (!ended.contains(s.id)) s,
  ];

  @override
  Future<void> endSession(String sessionId) async => ended.add(sessionId);
}

SessionSummary _summary(String id, List<String> argv) => SessionSummary(
  id: id,
  argv: argv,
  workingDirectory: '/work',
  pid: 42,
  columns: 120,
  rows: 40,
  startedAt: testTime,
  observedAt: testTime,
  totalBytes: 2048,
  firstAvailableOffset: 0,
  lifecycle: const SessionRunning(),
  writeHolder: null,
);

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, _LocalHost host) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          localHostSessionAccessProvider.overrideWithValue(host),
        ],
        child: const MaterialApp(home: HostSessionsDialog.local()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists what the host holds, agents by their session title', (
    tester,
  ) async {
    SessionDao(db).insert(session(id: 's1', title: 'Fix the parser'));
    final host = _LocalHost([
      _summary('karmashala_s1', ['claude', '--resume', 'x']),
      _summary('karmashala_local_pane-1', ['/bin/zsh', '-l']),
    ]);
    await pump(tester, host);

    expect(find.text('Session host on this computer'), findsOneWidget);
    expect(find.text('Fix the parser'), findsOneWidget);
    expect(find.text('/bin/zsh -l'), findsOneWidget);
    expect(find.text('agent session'), findsOneWidget, reason: 'only agents');
    expect(find.text('Attach'), findsNothing);
  });

  testWidgets('End ends that one session and the list follows', (tester) async {
    final host = _LocalHost([
      _summary('karmashala_local_pane-1', ['/bin/zsh', '-l']),
    ]);
    await pump(tester, host);
    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    expect(host.ended, ['karmashala_local_pane-1']);
    expect(find.text('This host is holding nothing.'), findsOneWidget);
  });
}
