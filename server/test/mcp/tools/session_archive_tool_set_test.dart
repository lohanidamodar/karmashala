import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_archive_tool_set.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `session_archive` and `session_unarchive`: an agent tidies up the sessions
/// it spawned — its children and their descendants, once they have ended —
/// and nothing else.
void main() {
  final t0 = DateTime.utc(2026, 10, 6, 12);
  late AppDatabase database;
  late ServerToolContext context;
  late SessionArchiveToolSet tools;
  late Set<String> running;

  void insert(
    String id, {
    String? parent,
    SessionStatus status = SessionStatus.completed,
  }) => SessionDao(database).insert(
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

  Session row(String id) => SessionDao(database).getById(id)!;

  Future<Object?> call(String tool, String target, String? caller) =>
      tools.call(tool, {'sessionId': target}, caller)!;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    running = {};
    context = ServerToolContext(
      database: database,
      data: DataService(database, clock: () => t0, runsSession: running.contains),
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    tools = SessionArchiveToolSet(context);
    insert('lead', status: SessionStatus.running);
    insert('child', parent: 'lead');
    insert('grandchild', parent: 'child');
    insert('busy', parent: 'lead', status: SessionStatus.running);
    insert('stranger');
  });

  tearDown(() {
    context.close();
    database.close();
  });

  test('serves both tools with sessionId required', () {
    final names = {for (final s in tools.schemas) s['name']};
    expect(names, {'session_archive', 'session_unarchive'});
    for (final schema in tools.schemas) {
      final input = schema['inputSchema']! as Map<String, Object?>;
      expect(input['required'], ['sessionId']);
    }
  });

  test('archives an ended child and its ended descendants', () async {
    final answer = await call('session_archive', 'child', 'lead') as Map;
    expect(answer['archived'], ['child', 'grandchild']);
    expect(answer['leftLive'], isEmpty);
    expect(row('child').isArchived, isTrue);
    expect(row('grandchild').isArchived, isTrue);
  });

  test('a descendant further down counts as the caller\'s own', () async {
    await call('session_archive', 'grandchild', 'lead');
    expect(row('grandchild').isArchived, isTrue);
  });

  test('a live child is refused with the reason, and nothing is archived', () {
    expect(
      call('session_archive', 'busy', 'lead'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('still running')),
      ),
    );
    expect(row('busy').isArchived, isFalse);
  });

  test('a session the server runs is live whatever its row says', () {
    running.add('child');
    expect(call('session_archive', 'child', 'lead'), throwsStateError);
    expect(row('child').isArchived, isFalse);
  });

  test('a session that is not the caller\'s is refused', () {
    expect(
      call('session_archive', 'stranger', 'lead'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('not one you started'),
        ),
      ),
    );
    expect(call('session_archive', 'lead', 'child'), throwsStateError);
    expect(row('stranger').isArchived, isFalse);
    expect(row('lead').isArchived, isFalse);
  });

  test('a caller cannot archive itself, nor act without a session', () {
    expect(call('session_archive', 'child', 'child'), throwsStateError);
    expect(call('session_archive', 'child', null), throwsStateError);
    expect(
      tools.call('session_archive', const {}, 'lead'),
      throwsArgumentError,
    );
  });

  test('an unknown session is refused', () {
    expect(call('session_archive', 'never', 'lead'), throwsStateError);
  });

  test('unarchive follows the same rules and restores the descendants', () async {
    await call('session_archive', 'child', 'lead');
    expect(call('session_unarchive', 'child', 'stranger'), throwsStateError);

    final answer = await call('session_unarchive', 'child', 'lead') as Map;
    expect(answer['unarchived'], ['child', 'grandchild']);
    expect(row('child').isArchived, isFalse);
  });
}
