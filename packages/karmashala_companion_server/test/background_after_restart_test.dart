import 'dart:io';

import 'package:agent_cli/read.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Claude Code restarted in its pane on the same version leaves no marker in
/// the transcript, so a background run it had going still read "running". The
/// server knows when it last started the pane: a run begun before that, with
/// no end recorded, is over unsaid.
void main() {
  final before = DateTime.utc(2026, 10, 5, 6);
  final restarted = before.add(const Duration(minutes: 30));
  final after = restarted.add(const Duration(minutes: 5));
  late Directory dir;
  late File record;
  late AppDatabase database;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('records_restart');
    record = File('${dir.path}/s1.jsonl')..writeAsStringSync('{}');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Waiting on agents',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: before,
      ),
    );
  });
  tearDown(() {
    database.close();
    dir.deleteSync(recursive: true);
  });

  TranscriptMessage launch(String id, DateTime at, BackgroundRunState state) =>
      TranscriptMessage(
        role: 'tool',
        text: 'Agent($id)',
        at: at,
        background: BackgroundRun(
          id: id,
          kind: BackgroundRunKind.agent,
          state: state,
          description: 'job $id',
        ),
      );

  SessionsAtRest atRest({DateTime? paneStartedAt}) => SessionsAtRest(
    sessions: SessionDao(database),
    names: WorkspaceNames(database),
    screens: _Pane(paneStartedAt),
    hostName: 'droplet',
    recordOf: (_) => (path: record.path, agentId: 'claudeCode'),
    records: AgentRecords(
      read: (path, agentId) async => [
        launch('old', before, BackgroundRunState.running),
        launch('new', after, BackgroundRunState.running),
      ],
    ),
    clock: () => after,
  );

  test('a run begun before its pane last started, with no end recorded, is '
      'not running', () async {
    final service = atRest(paneStartedAt: restarted);
    final runs = {
      for (final run in (await service.transcript('s1')).activity.background)
        run.id: run.state,
    };
    expect(runs, {'old': 'ended', 'new': 'running'});

    final polled = await service.recordState('s1');
    expect(
      {for (final run in polled.activity!.background) run.id: run.state},
      runs,
      reason: 'the memo answers the same',
    );
  });

  test('with no pane start known, nothing is changed', () async {
    final runs = (await atRest().transcript('s1')).activity.background;
    expect(runs.where((r) => r.isRunning).map((r) => r.id), ['old', 'new']);
  });
}

class _Pane implements CompanionScreens {
  _Pane(this.startedAt);

  final DateTime? startedAt;

  @override
  List<HostedSessionView> sessions() => [?_view];

  @override
  HostedSessionView? find(String hostSessionId) =>
      hostSessionId == hostSessionIdOf('s1') ? _view : null;

  HostedSessionView? get _view {
    final at = startedAt;
    return at == null
        ? null
        : (
            hostSessionId: hostSessionIdOf('s1'),
            command: 'claude',
            running: true,
            exitCode: null,
            startedAt: at,
          );
  }

  @override
  String? screenText(String hostSessionId) => null;

  @override
  int? outputOffset(String hostSessionId) => null;

  @override
  Future<void> type(String hostSessionId, String text) async {}
}
