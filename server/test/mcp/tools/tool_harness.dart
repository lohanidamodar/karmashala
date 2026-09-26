import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_set.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

/// A store with the rows the tool tests share, a real [DataService] over it,
/// and the [ServerToolContext] a family runs in: projects p1 (Demo) and p2
/// (Karmashala), checkout r1 in p1, a Claude Code installation a1, and
/// sessions s1 and s2 in r1 — the app tests' own world.
class ToolHarness {
  ToolHarness() {
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    client = service.open((_) {});
    here = localHostEnvironment(now);
    ExecutionEnvironmentDao(db).upsert(here);
    for (final (id, name) in [('p1', 'Demo'), ('p2', 'Karmashala')]) {
      db.execute(
        'INSERT INTO projects '
        '(id, name, root_environment_id, root_path, created_at) '
        'VALUES (?, ?, ?, ?, ?);',
        [id, name, here.id, '/src/$id', _at],
      );
    }
    addRepository('r1', project: 'p1', name: 'app');
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claudeCode', ?, '/usr/local/bin/claude', ?);",
      [here.id, _at],
    );
    addSession('s1', title: 'Fix login');
    addSession('s2', title: 'The verifier');
    tmp = Directory.systemTemp.createTempSync('karmashala_server_tools_');
    context = ServerToolContext(
      database: db,
      data: service,
      dataDirectory: tmp.path,
      clock: () => now,
      newId: () => 'id-${++_ids}',
    );
  }

  static const _at = '2026-01-01T00:00:00.000Z';

  final DateTime now = DateTime.utc(2026, 9, 27, 12);
  late final AppDatabase db;
  late final DataService service;
  late final DataSession client;
  late final ExecutionEnvironment here;
  late final ServerToolContext context;
  late final Directory tmp;
  var _ids = 0;

  void addRepository(
    String id, {
    String project = 'p1',
    String? name,
    String? environmentId,
  }) => db.execute(
    'INSERT INTO repositories '
    '(id, project_id, name, environment_id, path, created_at) '
    'VALUES (?, ?, ?, ?, ?, ?);',
    [id, project, name ?? id, environmentId ?? here.id, '/src/$id', _at],
  );

  Session addSession(
    String id, {
    String title = 'Work',
    String repositoryId = 'r1',
    String? conversation,
  }) => client
      .handle(
        SessionCreate(
          Session(
            id: id,
            repositoryId: repositoryId,
            agentInstallationId: 'a1',
            title: title,
            useWorktree: false,
            status: SessionStatus.running,
            createdAt: now,
            externalSessionId: conversation,
          ),
        ),
      )
      .value;

  /// [family] runs [tool] as [caller] would call it.
  Future<Object?> call(
    ServerToolSet family,
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller,
  ]) => family.call(tool, arguments, caller)!;

  /// [call], answered as the map a structured tool answers.
  Future<Map<String, Object?>> map(
    ServerToolSet family,
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller,
  ]) async =>
      (await call(family, tool, arguments, caller))! as Map<String, Object?>;

  void dispose() {
    context.close();
    service.conversations.close();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}
