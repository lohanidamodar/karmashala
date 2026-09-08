import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/process_spawn.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/cli_detection/application/codex_app_server_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_servers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/git/domain/file_change.dart';
import 'package:karmashala/src/features/git/domain/file_edit.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_changed_files_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_changed_files.dart';

import '../../support/fake_codex_app_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A transcript locator that answers from a variable, so nothing here walks the
/// owner's real `~/.claude`.
class _FixedLocator implements SessionTranscriptLocator {
  _FixedLocator(this.path);
  String? path;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => path;

  @override
  Future<Map<String, String>> index() async =>
      path == null ? const {} : {'x': path!};
}

/// **What a session changed, and the three different ways of not knowing.**
///
/// Every case here exists because collapsing it into an empty list is the bug:
/// "this session changed no files", "we could not read this session's record"
/// and "this agent keeps no record, so only git can answer" are three sentences
/// and one of them is a lie in the other two's place (§19).
///
/// Nothing spawns a real `codex`, reads a real store or shells out to git: the
/// Codex app-server is a [FakeCodexAppServer] over a [FakeProcessHandle], the
/// Claude transcript is a file this test wrote into a temp directory, and the
/// git fallback is the checkpoint chain, which is already in the database.
void main() {
  late AppDatabase db;
  late Directory tmp;
  late _FixedLocator locator;
  late FakeCodexAppServer codex;
  late List<CommandRequest> started;

  /// The pool the app itself uses, over a runner that hands back scripted JSON.
  CodexAppServers poolFor(AppDatabase db) => CodexAppServers(
    runnerFactory: FakeCommandRunnerFactory(
      fallback: FakeCommandRunner(
        processFactory: (request) {
          started.add(request);
          return codex;
        },
      ),
    ),
    environments: ExecutionEnvironmentDao(db),
    installations: AgentInstallationDao(db),
  );

  ProviderContainer containerFor() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      codexAppServersProvider.overrideWith((ref) {
        final pool = poolFor(db);
        ref.onDispose(pool.closeAll);
        return pool;
      }),
      sessionTranscriptLocatorProvider.overrideWithValue(locator),
    ],
  );

  /// One `full` turn holding [changes].
  Map<String, Object?> turn(List<Map<String, Object?>> changes) => {
    'id': 't',
    'itemsView': 'full',
    'status': 'completed',
    'items': [
      {'type': 'fileChange', 'id': 'exec-1', 'changes': changes},
    ],
  };

  FakeCodexAppServer codexAnswering(Object? result) => FakeCodexAppServer(
    reply: (_, id, method, params) => jsonEncode({'id': id, 'result': result}),
  );

  void installAgent(String agentId, {String environmentId = 'windows'}) {
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: agentId, environmentId: environmentId),
    );
  }

  void checkpoint(List<FileChange> files, {int sequence = 1}) {
    CheckpointDao(db).insert(
      Checkpoint(
        id: 'ck$sequence',
        sessionId: 's1',
        repository: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
        sequence: sequence,
        treeSha: 'tree$sequence',
        commitSha: 'commit$sequence',
        parentCommitSha: null,
        headSha: 'head1',
        reason: CheckpointReason.turn,
        createdAt: testTime,
        files: files,
      ),
    );
  }

  Future<SessionChangedFilesReport> read(ProviderContainer container) =>
      container.read(sessionChangedFilesServiceProvider).read('s1');

  setUp(() {
    db = AppDatabase.memory();
    tmp = Directory.systemTemp.createTempSync('karmashala_changed_');
    started = [];
    locator = _FixedLocator(null);
    codex = codexAnswering(<String, Object?>{'data': <Object?>[]});
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ExecutionEnvironmentDao(db).upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  /// A Codex session on [environmentId], with the thread id its record is
  /// filed under.
  void codexSession({String environmentId = 'windows'}) {
    installAgent(AgentIds.codex, environmentId: environmentId);
    SessionDao(db).insert(session().copyWith(externalSessionId: 'thread-1'));
  }

  group('Codex answers out of its own turns', () {

    test('every changed path and kind, folded onto one row per file', () async {
      codexSession();
      codex = codexAnswering({
        'data': [
          turn([
            {
              'path': r'C:\src\demo\app\lib\a.dart',
              'kind': {'type': 'add'},
            },
            {
              'path': r'C:\src\demo\app\lib\a.dart',
              'kind': {'type': 'update', 'move_path': null},
            },
            {
              'path': r'C:\src\demo\app\lib\b.dart',
              'kind': {'type': 'delete'},
            },
          ]),
        ],
        'nextCursor': null,
      });
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.fromAgentRecord);
      expect(report.files.length, 2);
      expect(
        report.files.first.kind,
        FileEditKind.created,
        reason:
            'a file this session created stays created however often it was '
            'edited afterwards — the strongest claim wins',
      );
      expect(report.files.last.kind, FileEditKind.deleted);
      expect(report.headline, contains('2 files'));
      expect(report.headline, contains('Codex CLI’s own record'));
      expect(report.caveat, isNull);
      expect(report.checkedAt, testTime);
    });

    test('a thread that changed nothing says so; it is not a failure', () async {
      codexSession();
      codex = codexAnswering({'data': <Object?>[], 'nextCursor': null});
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(
        report.outcome,
        SessionChangedFilesOutcome.agentRecordNamesNoFile,
      );
      expect(report.gap, SessionRecordGap.none);
      expect(report.headline, 'Codex CLI’s record of this session names no changed file.');
    });

    test('a record that could not be read never reads as nothing changed', () async {
      codexSession();
      codex = FakeCodexAppServer(
        reply: (_, id, method, params) => jsonEncode({
          'error': {'code': -32600, 'message': 'thread not loaded: thread-1'},
          'id': id,
        }),
      );
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.nothingCanAnswer);
      expect(report.gap, SessionRecordGap.recordUnreadable);
      expect(report.detail, contains('thread not loaded'));
      expect(report.headline, contains('could not be read'));
      expect(report.headline, contains('no checkpoint to fall back on'));
      expect(report.files, isEmpty);
    });

    test('a session that has not named a thread yet says that, not nothing', () async {
      codexSession();
      SessionDao(db).updateExternalSessionId('s1', '');
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.gap, SessionRecordGap.noConversationYet);
      expect(report.headline, contains('has not named a Codex CLI conversation yet'));
    });

    test('a WSL session\u2019s POSIX paths reach the host through the one translator', () async {
      codexSession(environmentId: 'wsl:Ubuntu');
      codex = codexAnswering({
        'data': [
          turn([
            {
              'path': '/home/me/app/lib/a.dart',
              'kind': {'type': 'update', 'move_path': null},
            },
          ]),
        ],
        'nextCursor': null,
      });
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      final file = report.files.single;
      expect(file.path, '/home/me/app/lib/a.dart', reason: 'the record verbatim');
      expect(file.hostPath, r'\\wsl.localhost\Ubuntu\home\me\app\lib\a.dart');
      expect(file.display, file.hostPath);
    });

    test('the connection is the pool\u2019s, and a second read opens none', () async {
      codexSession();
      codex = codexAnswering({'data': <Object?>[], 'nextCursor': null});
      final container = containerFor();
      addTearDown(container.dispose);
      final before = processSpawnsOnThisIsolate;

      await read(container);
      await read(container);

      expect(
        started.length,
        1,
        reason:
            'one connection per environment, reused — the pool is what turns a '
            '~1 s spawn into a one-off',
      );
      expect(
        container.read(codexAppServersProvider).openConnections,
        1,
      );
      expect(
        processSpawnsOnThisIsolate,
        before,
        reason: 'nothing in this reading creates a process of its own',
      );
    });
  });

  group('Claude Code answers out of its own transcript', () {
    setUp(() {
      installAgent(AgentIds.claudeCode);
      SessionDao(db).insert(session().copyWith(externalSessionId: 'conv-1'));
    });

    String transcript(List<Map<String, Object?>> lines) {
      final file = File('${tmp.path}/conv-1.jsonl')
        ..writeAsStringSync(lines.map(jsonEncode).join('\n'));
      return file.path;
    }

    Map<String, Object?> toolUse(String name, Map<String, Object?> input) => {
      'type': 'assistant',
      'message': {
        'content': [
          {'type': 'tool_use', 'id': 'tu1', 'name': name, 'input': input},
        ],
      },
    };

    test('a Write and an Edit become one row each, by path', () async {
      locator.path = transcript([
        toolUse('Write', {
          'file_path': r'C:\src\demo\app\lib\new.dart',
          'content': 'x',
        }),
        toolUse('Edit', {
          'file_path': r'C:\src\demo\app\lib\old.dart',
          'old_string': 'a',
          'new_string': 'b',
        }),
        toolUse('Edit', {
          'file_path': r'C:\src\demo\app\lib\old.dart',
          'old_string': 'b',
          'new_string': 'c',
        }),
        toolUse('Bash', {'command': 'rm -rf /'}),
        toolUse('Read', {'file_path': r'C:\src\demo\app\lib\untouched.dart'}),
      ]);
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.fromAgentRecord);
      expect(
        report.files.map((f) => f.display),
        [r'C:\src\demo\app\lib\new.dart', r'C:\src\demo\app\lib\old.dart'],
        reason: 'a read is not a change, and a command names no file',
      );
    });

    test('a transcript we cannot find is unreadable, not empty', () async {
      locator.path = null;
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.gap, SessionRecordGap.recordUnreadable);
      expect(report.detail, contains('no transcript'));
      expect(report.outcome, SessionChangedFilesOutcome.nothingCanAnswer);
    });

    test('a transcript with no write in it names no file, and says so', () async {
      locator.path = transcript([
        toolUse('Bash', {'command': 'ls'}),
      ]);
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.agentRecordNamesNoFile);
      expect(report.headline, contains('Claude Code’s record'));
    });
  });

  group('an agent that keeps no record falls back to git', () {
    setUp(() {
      installAgent(AgentIds.antigravity);
      SessionDao(db).insert(session().copyWith(externalSessionId: 'ag-1'));
    });

    test('the checkpoint chain answers, and the caveat says what it is', () async {
      checkpoint(const [
        FileChange(
          path: 'lib/a.dart',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
        FileChange(
          path: 'lib/new.dart',
          type: FileChangeType.added,
          staged: false,
          unstaged: true,
        ),
      ]);
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.fromCheckpoints);
      expect(report.gap, SessionRecordGap.agentKeepsNoRecord);
      expect(report.files.map((f) => f.display), ['lib/a.dart', 'lib/new.dart']);
      expect(report.files.last.kind, FileEditKind.created);
      expect(report.caveat, contains('Antigravity keeps no record'));
      expect(
        report.caveat,
        contains('already uncommitted when this session’s first turn ended'),
        reason:
            'the first checkpoint is measured against HEAD, so it carries '
            'whatever the tree was already dirty with',
      );
      expect(report.caveat, contains('not isolated in worktrees'));
    });

    test('no checkpoint means no baseline, and it is never invented', () async {
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.nothingCanAnswer);
      expect(report.gap, SessionRecordGap.agentKeepsNoRecord);
      expect(
        report.headline,
        'Antigravity keeps no record of what it changed, and this session has '
        'no checkpoint — so nothing here can answer.',
      );
      expect(report.files, isEmpty);
    });

    test('a checkpoint that recorded nothing is its own sentence', () async {
      checkpoint(const []);
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.checkpointsNameNoFile);
      expect(
        report.headline,
        'No checkpoint of this session recorded a changed file.',
      );
    });

    test('a move arrives as its two halves, because git was asked that way', () async {
      // `CheckpointService` diffs with `--no-renames`, and
      // `session_checkpoint_files` has nowhere to keep an old name. So a moved
      // file is a delete and an add here, and claiming a rename would be
      // inventing a link the chain does not record.
      checkpoint(const [
        FileChange(
          path: 'lib/old.dart',
          type: FileChangeType.deleted,
          staged: false,
          unstaged: true,
        ),
        FileChange(
          path: 'lib/new.dart',
          type: FileChangeType.added,
          staged: false,
          unstaged: true,
        ),
      ]);
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.files.map((f) => '${f.kind.name} ${f.path}'), [
        'created lib/new.dart',
        'deleted lib/old.dart',
      ]);
      expect(report.files.every((f) => f.movedTo == null), isTrue);
    });
  });

  group('when the agent record fails, git still answers, and says why', () {
    test('Codex could not be read, so the checkpoints did', () async {
      installAgent(AgentIds.codex);
      SessionDao(db).insert(session().copyWith(externalSessionId: 'thread-1'));
      codex = FakeCodexAppServer(
        reply: (_, id, method, params) => jsonEncode({
          'error': {'code': -32600, 'message': 'thread not loaded'},
          'id': id,
        }),
      );
      checkpoint(const [
        FileChange(
          path: 'lib/a.dart',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
      ]);
      final container = containerFor();
      addTearDown(container.dispose);

      final report = await read(container);

      expect(report.outcome, SessionChangedFilesOutcome.fromCheckpoints);
      expect(report.gap, SessionRecordGap.recordUnreadable);
      expect(report.headline, '1 file, from this session’s checkpoints.');
      expect(report.caveat, contains('could not be read'));
      expect(report.caveat, contains('thread not loaded'));
    });
  });

  test('a session that is not there says so rather than nothing', () async {
    final container = containerFor();
    addTearDown(container.dispose);

    final report = await container
        .read(sessionChangedFilesServiceProvider)
        .read('gone');

    expect(report.outcome, SessionChangedFilesOutcome.unknownSession);
    expect(report.headline, 'There is no such session.');
  });
}
