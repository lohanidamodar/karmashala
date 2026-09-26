import 'dart:io';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// What the server records about an agent CLI it found, in rows it shares
/// with the desktop app: the app's own rules hold — a pinned path stands, a
/// moved CLI keeps its row and id, and the same CLI is one row whoever
/// records it first.
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 12);
  late AppDatabase database;
  late AgentInstallationRows rows;
  late Directory dir;

  setUp(() {
    database = AppDatabase.memory();
    rows = AgentInstallationRows(database)
      ..ensureEnvironment(localHostEnvironment(t0));
    dir = Directory.systemTemp.createTempSync('agent-rows-');
  });
  tearDown(() {
    database.close();
    dir.deleteSync(recursive: true);
  });

  String file(String name) => (File('${dir.path}/$name')..createSync()).path;

  AgentInstallation found(String id, String path, {String? version}) =>
      AgentInstallation(
        id: id,
        agentId: 'claudeCode',
        executable: EnvironmentPath(
          environmentId: localHostEnvironmentId,
          path: path,
        ),
        version: version,
        versionReadAt: version == null ? null : t0,
        createdAt: t0,
      );

  void insert(String id, String path, {bool byUser = false}) =>
      database.execute(
        'INSERT INTO agent_installations (id, agent_kind, environment_id, '
        'executable_path, created_at, executable_by_user) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [
          id,
          'claudeCode',
          localHostEnvironmentId,
          path,
          t0.toIso8601String(),
          byUser ? 1 : 0,
        ],
      );

  test('a new CLI is a new row; the same one again is its version only', () {
    final path = file('claude');
    expect(rows.record(found('a', path))!.added, isTrue);
    final again = rows.record(found('b', path, version: '2.0.0'))!;
    expect(again.added, isFalse);
    expect(again.installation.id, 'a');
    expect(again.installation.version, '2.0.0');
    expect(rows.inEnvironment(localHostEnvironmentId), hasLength(1));
  });

  test('a path a person pinned, that still opens, is not overruled', () {
    insert('mine', file('my-claude'), byUser: true);
    expect(rows.record(found('found', file('claude'))), isNull);
    expect(rows.inEnvironment(localHostEnvironmentId).single.id, 'mine');
  });

  test('a CLI that moved keeps its row and id', () {
    insert('kept', '${dir.path}/gone/claude');
    final moved = rows.record(found('new', file('claude'), version: '3'))!;
    expect(moved.added, isFalse);
    expect(moved.installation.id, 'kept');
    expect(moved.installation.executable.path, '${dir.path}/claude');
    expect(rows.inEnvironment(localHostEnvironmentId), hasLength(1));
  });

  test('a second install beside one that still opens is a second row', () {
    insert('one', file('claude-a'));
    expect(rows.record(found('two', file('claude-b')))!.added, isTrue);
    expect(rows.inEnvironment(localHostEnvironmentId), hasLength(2));
  });
}
