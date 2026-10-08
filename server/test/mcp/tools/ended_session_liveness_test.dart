import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_archive_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// A session whose process ended is still held by the registry for a while.
/// `session_end` and `session_archive` must read that the same way: nothing
/// runs it, so there is nothing to end and it may be archived.
void main() {
  final t0 = DateTime.utc(2026, 10, 9, 12);
  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late ServerToolContext context;
  late SessionToolSet sessionTools;
  late SessionArchiveToolSet archiveTools;

  void insert(String id, {String? parent, required SessionStatus status}) =>
      SessionDao(database).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Work $id',
          useWorktree: false,
          status: status,
          createdAt: t0,
          parentSessionId: parent,
        ),
      );

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    context = ServerToolContext(
      database: database,
      data: DataService(database, clock: () => t0, runsSession: status.holds),
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    sessionTools = SessionToolSet(
      context,
      prompts: DaemonPromptAnswers(status: status, database: database),
      registry: registry,
    );
    archiveTools = SessionArchiveToolSet(context);
    insert('lead', status: SessionStatus.running);
  });

  tearDown(() async {
    context.close();
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  Future<FakePtyHandle> start(String id) async {
    registry.open(
      'karmashala_$id',
      const PtySpawnRequest(argv: ['codex'], workingDirectory: '/src'),
    );
    await pumpEventQueue();
    return launcher.handles.last;
  }

  Future<Object?> archive(String id) =>
      archiveTools.call('session_archive', {'sessionId': id}, 'lead')!;

  Future<Object?> end(String id) =>
      sessionTools.call('session_end', {'sessionId': id}, 'lead')!;

  test('while it runs, archive refuses and end would end it', () async {
    insert('child', parent: 'lead', status: SessionStatus.completed);
    await start('child');
    expect(status.holds('child'), isTrue);
    await expectLater(
      archive('child'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('is still running'),
        ),
      ),
    );
  });

  for (final (label, rowStatus, exitCode) in [
    ('failed at once (exit 1)', SessionStatus.failed, 1),
    ('completed', SessionStatus.completed, 0),
  ]) {
    test('a process that $label: end says nothing runs it, and archive '
        'archives it', () async {
      insert('child', parent: 'lead', status: rowStatus);
      final agent = await start('child');
      agent.finish(exitCode);
      await pumpEventQueue();
      // The registry still holds it — the very case that disagreed.
      expect(registry.findProcess('karmashala_child'), isNotNull);
      expect(status.holds('child'), isFalse);

      await expectLater(
        end('child'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('Nothing is running that session'),
          ),
        ),
      );
      final answer = await archive('child') as Map;
      expect(answer['archived'], ['child']);
      expect(SessionDao(database).getById('child')!.isArchived, isTrue);
    });
  }
}
