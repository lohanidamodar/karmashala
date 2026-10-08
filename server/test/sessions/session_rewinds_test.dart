import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/read.dart' show RewindMarker;
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionRewind;
import 'package:karmashala_git/git.dart' show FileChange, FileChangeType;
import 'package:karmashala_host/src/acp/acp_extensions.dart';
import 'package:karmashala_host/src/sessions/rewind/rewind_cuts.dart';
import 'package:karmashala_host/src/sessions/rewind/session_rewinds.dart';
import 'package:karmashala_host/src/sessions/rewind/terminal_rewind.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

const _repo = EnvironmentPath(environmentId: 'local', path: '/src/demo');

Checkpoint _checkpoint(String id, int turn) => Checkpoint(
  id: id,
  sessionId: 's1',
  repository: _repo,
  sequence: turn,
  treeSha: 'tree$turn',
  commitSha: 'c$turn',
  parentCommitSha: null,
  headSha: 'head',
  reason: CheckpointReason.turnStart,
  createdAt: DateTime.utc(2026, 10, 8),
  turn: turn,
);

/// What the files half was asked, in order.
class _Files implements RewindFiles {
  _Files(this.events);

  final List<String> events;
  CheckpointConflict? conflictWith;
  String? refuse;

  @override
  List<Checkpoint> checkpointsFor({
    required String sessionId,
    String? checkpointId,
    int? turn,
  }) => [_checkpoint('k$turn', turn ?? 0)];

  @override
  String? refusal(Checkpoint checkpoint, {required String sessionId}) => refuse;

  @override
  Future<RestorePreview> preview(Checkpoint checkpoint) async =>
      const RestorePreview(
        files: ['lib/a.dart', 'lib/b.dart'],
        outside: ['notes.md'],
        headMoved: false,
      );

  @override
  Future<CheckpointConflict?> conflict(Checkpoint checkpoint) async =>
      conflictWith;

  @override
  Future<CheckpointRestoreAnswer> restore(
    Checkpoint checkpoint, {
    required bool confirm,
  }) async {
    events.add('restore ${checkpoint.id} confirm=$confirm');
    return CheckpointRestoreAnswer.restored(
      RestoreOutcome(
        restored: checkpoint,
        safetyCheckpoint: _checkpoint('safety', 9),
        files: const [
          FileChange(
            path: 'lib/a.dart',
            type: FileChangeType.modified,
            staged: false,
            unstaged: true,
          ),
        ],
        alreadyThere: false,
      ),
    );
  }
}

class _Terminal implements TerminalRewind {
  _Terminal(this.events);

  final List<String> events;

  @override
  Future<void> rewind(
    String sessionId, {
    required int back,
    required RewindMenu menu,
    String words = '',
  }) async => events.add('menu back=$back "$words"');
}

String _line(Map<String, Object?> record) => jsonEncode(record);

/// Claude's record of three turns: "one", "two", "three".
final _record = [
  _line({
    'type': 'user',
    'uuid': 'u1',
    'parentUuid': null,
    'message': {'role': 'user', 'content': 'one'},
  }),
  _line({'type': 'assistant', 'uuid': 'a1', 'parentUuid': 'u1'}),
  _line({
    'type': 'user',
    'uuid': 'u2',
    'parentUuid': 'a1',
    'message': {'role': 'user', 'content': 'two'},
  }),
  _line({'type': 'assistant', 'uuid': 'a2', 'parentUuid': 'u2'}),
  _line({
    'type': 'user',
    'uuid': 'u3',
    'parentUuid': 'a2',
    'message': {'role': 'user', 'content': 'three'},
  }),
  _line({'type': 'assistant', 'uuid': 'a3', 'parentUuid': 'u3'}),
];

void main() {
  late AppDatabase database;
  late SessionMessageDao messages;
  late List<String> events;
  late _Files files;
  late RewindCuts cuts;
  late bool working;
  late bool running;
  late String agent;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Colours',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: DateTime.utc(2026, 10, 8),
        externalSessionId: 'conv-1',
      ),
    );
    messages = SessionMessageDao(database);
    events = [];
    files = _Files(events);
    cuts = RewindCuts();
    working = false;
    running = true;
    agent = 'claude-acp';
    var ids = 0;
    for (final (role, text) in [
      (SessionMessageRole.user, 'one'),
      (SessionMessageRole.agent, 'did one'),
      (SessionMessageRole.user, 'two'),
      (SessionMessageRole.agent, 'did two'),
      (SessionMessageRole.user, 'three'),
      (SessionMessageRole.agent, 'did three'),
    ]) {
      messages.append(
        SessionMessage(
          id: 'm${ids++}',
          sessionId: 's1',
          role: role,
          text: text,
          createdAt: DateTime.utc(2026, 10, 8),
          updatedAt: DateTime.utc(2026, 10, 8),
        ),
      );
    }
  });
  tearDown(() => database.close());

  SessionRewinds rewinds() => SessionRewinds(
    sessions: SessionDao(database),
    agentOf: (_) => agent,
    registry: () => AgentRegistry.builtIn,
    messages: messages,
    transcriptLines: (_) async => _record,
    cuts: cuts,
    runsHere: (_) => running,
    end: (_) async => events.add('end'),
    resume: (_) async => events.add('resume'),
    files: files,
    terminal: _Terminal(events),
    turnRunning: (_) => working,
    holdQueue: (_) => events.add('hold'),
    releaseQueue: (_) => events.add('release'),
  );

  SessionRewind request(
    RewindMode mode, {
    int turnIndex = 1,
    String words = 'two',
    bool preview = false,
    bool confirm = false,
  }) => SessionRewind(
    sessionId: 's1',
    turnIndex: turnIndex,
    words: words,
    mode: mode.name,
    checkpointTurn: mode.restoresCode ? 2 : null,
    preview: preview,
    confirm: confirm,
  );

  List<SessionMessage> rows() => messages.listAfter('s1');

  test('a preview counts the later turns, the files and the outside changes, '
      'and changes nothing', () async {
    final answer = await rewinds().rewind(
      request(RewindMode.both, preview: true),
    );
    expect(answer['turns'], 2);
    expect(answer['files'], 2);
    expect(answer['outside'], ['notes.md']);
    expect((answer['conversation']! as Map)['cut'], isTrue);
    expect(events, isEmpty);
    expect(cuts.cutOf('s1'), isNull);
  });

  test('code only restores the files and leaves the conversation', () async {
    final answer = await rewinds().rewind(
      request(RewindMode.code, confirm: true),
    );
    expect(events, ['hold', 'restore k2 confirm=true', 'release']);
    expect(cuts.cutOf('s1'), isNull);
    expect(answer['files'], 1);
    expect(answer['composerText'], 'two');
    expect(rows().last.role, SessionMessageRole.notice);
    expect(rows().last.messageId, isNull, reason: 'no turn is folded');
    expect(rows().last.text, contains('conversation is unchanged'));
  });

  test('conversation only cuts at the entry before the message, restarts the '
      'agent with the queue held, and leaves the files', () async {
    final answer = await rewinds().rewind(request(RewindMode.conversation));
    expect(events, ['hold', 'end', 'resume', 'release']);
    expect(cuts.cutOf('s1'), 'a1');
    expect(answer['turns'], 2);
    final marker = rows().last;
    expect(marker.messageId, AcpExtensions.rewoundMessageId);
    final parsed = RewindMarker.parse(marker.text)!;
    expect(parsed.turns, 2);
    expect(parsed.mode, RewindMode.conversation);
  });

  test('both restores the files before the conversation is cut', () async {
    await rewinds().rewind(request(RewindMode.both, confirm: true));
    expect(events, [
      'hold',
      'restore k2 confirm=true',
      'end',
      'resume',
      'release',
    ]);
    expect(cuts.cutOf('s1'), 'a1');
  });

  test(
    'a session nothing runs is cut for its next start, not started',
    () async {
      running = false;
      await rewinds().rewind(request(RewindMode.conversation));
      expect(events, ['hold', 'release']);
      expect(cuts.cutOf('s1'), 'a1');
    },
  );

  test('rewinding the first message starts the conversation over', () async {
    await rewinds().rewind(
      request(RewindMode.conversation, turnIndex: 0, words: 'one'),
    );
    expect(cuts.cutOf('s1'), isNull);
    expect(SessionDao(database).getById('s1')!.externalSessionId, '');
  });

  test('a message already rewound is refused, and the next rewind counts '
      'only the turns still live', () async {
    await rewinds().rewind(request(RewindMode.conversation));
    events.clear();
    await expectLater(
      rewinds().rewind(
        request(RewindMode.conversation, turnIndex: 2, words: 'three'),
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'why', contains('already')),
      ),
    );
    expect(events, isEmpty);
  });

  test('refused while the agent works, with nothing changed', () async {
    working = true;
    await expectLater(
      rewinds().rewind(request(RewindMode.both, confirm: true)),
      throwsA(
        isA<StateError>().having((e) => e.message, 'why', kRewindWhileWorking),
      ),
    );
    expect(events, isEmpty);
  });

  test('files changed outside the agent are refused without confirm, before '
      'anything is written', () async {
    files.conflictWith = CheckpointConflict(
      'moved',
      safetyCheckpoint: _checkpoint('safe', 7),
    );
    await expectLater(
      rewinds().rewind(request(RewindMode.both)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'why',
          contains('outside the agent'),
        ),
      ),
    );
    expect(events, ['hold', 'release']);
    expect(cuts.cutOf('s1'), isNull);
  });

  test(
    'an agent with no conversation cut is refused for it, in words',
    () async {
      agent = AgentIds.codex;
      await expectLater(
        rewinds().rewind(request(RewindMode.conversation)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'why',
            contains('Code only'),
          ),
        ),
      );
    },
  );

  test('a terminal session answers its agent\'s own menu, counting back from '
      'its record', () async {
    agent = AgentIds.claudeCode;
    final answer = await rewinds().rewind(
      request(RewindMode.both, confirm: true),
    );
    expect(events, [
      'hold',
      'restore k2 confirm=true',
      'menu back=1 "two"',
      'release',
    ]);
    expect(answer['turns'], 2);
    expect(cuts.cutOf('s1'), isNull, reason: 'the agent holds its own cut');
  });

  test('a terminal session nothing runs is refused: its menu is in the '
      'terminal', () async {
    agent = AgentIds.claudeCode;
    running = false;
    await expectLater(
      rewinds().rewind(request(RewindMode.conversation)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'why',
          contains('Open the terminal'),
        ),
      ),
    );
    expect(events, isEmpty);
  });
}
