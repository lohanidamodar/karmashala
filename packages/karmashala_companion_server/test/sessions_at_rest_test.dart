import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/host.dart' show RemoteApiRefusal;
import 'package:karmashala_remote/remote.dart' show ErrorCode;
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

  group('what the server decides (slice 5c: always the server\'s)', () {
    final imported = ImportedSession(
      id: 'imp-1',
      repositoryId: 'r1',
      cli: AgentIds.codex,
      externalId: 'conv-9',
      environmentId: 'local',
      filePath: '/store/conv-9.jsonl',
      storeHome: '/store',
      isSubagent: false,
      title: 'Old history',
      preview: 'hello',
      createdAt: t0,
    );
    late List<String> typed;

    SessionsAtRest served({
      AgentActivityStatus agent = AgentActivityStatus.idle,
      AgentWaitKind waiting = AgentWaitKind.unrecorded,
    }) {
      typed = [];
      return SessionsAtRest(
        sessions: SessionDao(database),
        names: WorkspaceNames(database),
        screens: _TypingScreens(typed),
        hostName: 'droplet',
        agentStatusOf: (sessionId) => AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: sessionId,
          status: agent,
          observedAt: t0,
          source: AgentStatusSource.hook,
          waiting: waiting,
        ),
        attentionOf: (id) => id == 'run' ? 'needs_approval' : null,
        usageLimitOf: (id) => id == 'run' ? 'Resets 14:05.' : null,
        agentIdOf: (_) => AgentIds.claudeCode,
        imported: () => [imported],
        clock: () => t0,
      );
    }

    void row(String id) => SessionDao(database).insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the cart',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: t0,
      ),
    );

    test('a row carries the server\'s attention, a limit\'s words and its '
        'agent\'s name', () {
      row('run');
      final snapshot = served().byId('run')!;
      expect(snapshot.attention, 'needs_approval');
      expect(snapshot.usageLimit, 'Resets 14:05.');
      expect(snapshot.agentLabel, startsWith('Claude Code'));
    });

    test('imported history is listed, read-only, and found by id', () {
      row('run');
      final listed = served().list();
      expect(listed.map((s) => s.sessionId), ['run', 'imp-1']);
      final history = served().byId('imp-1')!;
      expect(history.imported, isTrue);
      expect(history.status, 'imported');
      expect(history.attachments!.refusal, contains('imported history'));
    });

    test('a prompt is refused into imported history, and into an open '
        'prompt, in words', () async {
      row('run');
      await expectLater(
        served().sendPrompt('imp-1', 'hi'),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            contains('imported from the CLI'),
          ),
        ),
      );
      await expectLater(
        served(
          agent: AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.approval,
        ).sendPrompt('run', 'hi'),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            contains('waiting on a prompt'),
          ),
        ),
      );
      expect(typed, isEmpty);

      final atRest = served();
      await atRest.sendPrompt('run', 'hi');
      expect(typed, ['karmashala_run:hi']);
    });

    test('a prompt nobody here runs says why it cannot be answered', () {
      expect(
        served().notAnswerableHere('imp-1').message,
        contains('answer it in its own terminal'),
      );
      expect(
        served().notAnswerableHere('elsewhere').message,
        contains('not running in this Karmashala server'),
      );
    });
  });

  group('a session whose agent speaks a protocol', () {
    late List<String> typed;
    late List<String> delivered;

    SessionsAtRest atRestWith({String? refusal}) => SessionsAtRest(
      sessions: SessionDao(database),
      names: WorkspaceNames(database),
      screens: _TypingScreens(typed),
      hostName: 'droplet',
      // The server's own path: resuming it when nothing runs it, then a
      // turn — here, the ids it says are its own.
      deliverOverProtocol: (sessionId, text) async {
        if (sessionId != 'acp') return false;
        if (refusal != null) {
          throw RemoteApiRefusal(ErrorCode.badRequest, refusal);
        }
        delivered.add(text);
        return true;
      },
      clock: () => t0,
    );

    setUp(() {
      typed = [];
      delivered = [];
    });

    test('is sent to by its protocol, never typed into a screen; a terminal '
        'session still is', () async {
      final atRest = atRestWith();
      expect(await atRest.sendPrompt('acp', 'carry on'), isNotNull);
      await atRest.sendPrompt('pty', 'hi');
      expect(delivered, ['carry on']);
      expect(typed, ['karmashala_pty:hi']);
    });

    test(
      'a refusal reaches the phone in its words, and nothing is typed',
      () async {
        await expectLater(
          atRestWith(
            refusal: 'This session is not running and could not be resumed',
          ).sendPrompt('acp', 'carry on'),
          throwsA(
            isA<RemoteApiRefusal>().having(
              (r) => r.message,
              'message',
              contains('could not be resumed'),
            ),
          ),
        );
        expect(typed, isEmpty);
      },
    );
  });
}

class _TypingScreens extends _NoScreens {
  _TypingScreens(this.typed);
  final List<String> typed;
  @override
  Future<void> type(String hostSessionId, String text) async =>
      typed.add('$hostSessionId:$text');
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
