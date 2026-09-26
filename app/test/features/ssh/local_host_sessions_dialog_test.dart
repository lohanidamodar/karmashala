import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/presentation/host_sessions_dialog.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

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
  late TestMachine db;
  late FakeDataServer server;
  setUp(() {
    db = TestMachine();
    server = FakeDataServer().runsOn(db)
      ..environmentRows.upsert(localHostEnvironment(testTime))
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
  });

  Future<void> pump(WidgetTester tester, _LocalHost host) async {
    final workspace = await server.override();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          workspace,
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
    db.server.sessionRows.insert(session(id: 's1', title: 'Fix the parser'));
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
