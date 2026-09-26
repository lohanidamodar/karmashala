import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';
import 'package:karmashala_session_engine/store.dart';

/// What a phone is told about a row with no desktop connected. Found on a
/// phone: an ended (cancelled) session's header read "Idle", the last thing
/// its agent was seen doing.
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 12);
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
  });
  tearDown(() => database.close());

  SessionsAtRest atRest() => SessionsAtRest(
    sessions: SessionDao(database),
    names: WorkspaceNames(database),
    screens: _NoScreens(),
    hostName: 'droplet',
    // The agent was last seen at its prompt, whatever became of its session.
    agentStatusOf: (sessionId) => AgentStatusReport(
      agentId: 'claudeCode',
      sessionId: sessionId,
      status: AgentActivityStatus.idle,
      observedAt: t0,
      source: AgentStatusSource.hook,
    ),
    clock: () => t0,
  );

  String? activityOf(SessionStatus status) {
    SessionDao(database).insert(
      Session(
        id: status.name,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the cart',
        useWorktree: false,
        status: status,
        createdAt: t0,
      ),
    );
    return atRest().byId(status.name)!.activity;
  }

  test('a running row carries what its agent is doing', () {
    expect(activityOf(SessionStatus.running), 'idle');
    expect(activityOf(SessionStatus.idle), 'idle');
  });

  for (final ended in [
    SessionStatus.completed,
    SessionStatus.failed,
    SessionStatus.cancelled,
    SessionStatus.unknown,
  ]) {
    test('a ${ended.name} row carries no agent activity, only its ending', () {
      expect(activityOf(ended), isNull);
      final snapshot = atRest().byId(ended.name)!;
      expect(snapshot.status, ended.name);
    });
  }
}

class _NoScreens implements CompanionScreens {
  @override
  List<HostedSessionView> sessions() => const [];
  @override
  HostedSessionView? find(String hostSessionId) => null;
  @override
  String? screenText(String hostSessionId) => null;
  @override
  int? outputOffset(String hostSessionId) => null;
  @override
  Future<void> type(String hostSessionId, String text) async {}
}
