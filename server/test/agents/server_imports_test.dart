import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'agent_work_support.dart';

/// **The CLI import, by the server** (slice 2a): it reads the agents' own
/// stores in a temporary home — a Claude Code `projects/<dir>/<id>.jsonl`
/// here — and writes the imported history itself, told to every client:
/// for known checkouts (`imports.forRepositories`), or as found projects
/// (`imports.scan`, then `imports.add`). Nothing is imported twice.
void main() {
  final now = DateTime.utc(2026, 9, 26, 12);

  late Directory home;
  late String projectDir;
  late String otherDir;
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  late ServerAgentWork work;

  /// One Claude Code conversation that ran in [cwd].
  void writeClaudeSession(String cwd, String sessionId, String prompt) {
    final file = File(
      p.join(
        home.path,
        '.claude',
        'projects',
        claudeStoreDirectoryName(cwd),
        '$sessionId.jsonl',
      ),
    )..createSync(recursive: true);
    file.writeAsStringSync(
      '${[
        jsonEncode({
          'type': 'user',
          'cwd': cwd,
          'sessionId': sessionId,
          'timestamp': '2026-09-25T10:00:00.000Z',
          'message': {'role': 'user', 'content': prompt},
        }),
        jsonEncode({
          'type': 'assistant',
          'cwd': cwd,
          'sessionId': sessionId,
          'timestamp': '2026-09-25T10:00:05.000Z',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Done.'},
            ],
          },
        }),
      ].join('\n')}\n',
    );
  }

  List<DataChange> toldChanges() => [for (final b in told) ...b.changes];

  List<ImportedSession> imported() =>
      app.handle(const SessionsList()).value.imported;

  EnvironmentPath here(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  setUp(() {
    home = Directory.systemTemp.createTempSync('ks-imports-home');
    projectDir = p.join(home.path, 'work', 'proj');
    otherDir = p.join(home.path, 'work', 'other');
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    service.ensureEnvironment(localHostEnvironment(now));
    final clock = MutableClock(now);
    work = ServerAgentWork(
      data: service,
      clock: clock,
      ids: CountingIds('imp'),
      hostEnvironment: {'HOME': home.path, 'USERPROFILE': home.path},
      usageService: (_) => ScriptedUsageService(
        clock: clock,
        answer: (_) => throw UsageException('not in this test'),
      ),
      claudeAuth: ClaudeAuthService(
        ids: CountingIds('claude'),
        clock: clock,
        readKeychain: () async => const ClaudeKeychainRead.notFound(),
      ),
      onItsOwn: false,
    )..attach();
    writeClaudeSession(projectDir, 'sess-1', 'fix the flaky test');
    writeClaudeSession(otherDir, 'sess-2', 'somewhere else');
    told.clear();
  });

  tearDown(() {
    work.stop();
    db.close();
    home.deleteSync(recursive: true);
  });

  test('imports.forRepositories records a checkout\'s conversations as '
      'history, told; a second run adds nothing', () async {
    app.handle(ProjectCreate(projectName: 'proj', root: here(projectDir)));
    final checkout = app
        .handle(const WorkspaceList())
        .value
        .repositories
        .single;
    told.clear();

    final summary = (await app.handleLater(
      ImportsForRepositories([checkout.id]),
    )).value;
    expect(summary.sessions, 1);
    expect(summary.projects, 0);
    final record = imported().single;
    expect(record.externalId, 'sess-1');
    expect(record.cli, AgentIds.claudeCode);
    expect(record.repositoryId, checkout.id);
    expect(record.preview, 'fix the flaky test');
    expect(
      toldChanges().whereType<ImportedChanged>().single.session.externalId,
      'sess-1',
    );

    told.clear();
    final again = (await app.handleLater(
      ImportsForRepositories([checkout.id]),
    )).value;
    expect(again.isEmpty, isTrue);
    expect(imported(), hasLength(1));
    expect(toldChanges().whereType<ImportedChanged>(), isEmpty);
  });

  test('imports.forRepositories of no known checkout does nothing', () async {
    final summary = (await app.handleLater(
      const ImportsForRepositories(['ghost']),
    )).value;
    expect(summary.isEmpty, isTrue);
    expect(imported(), isEmpty);
  });

  test('imports.scan finds each folder\'s conversations and imports '
      'nothing', () async {
    final found = (await app.handleLater(const ImportsScan())).value;
    final project = found.singleWhere(
      (d) => d.sessions.any((s) => s.sessionId == 'sess-1'),
    );
    expect(project.sessions.single.cwd.path, projectDir);
    expect(project.sessions.single.preview, 'fix the flaky test');
    expect(found.expand((d) => d.sessions).map((s) => s.sessionId).toSet(), {
      'sess-1',
      'sess-2',
    });
    expect(imported(), isEmpty);
    expect(app.handle(const WorkspaceList()).value.projects, isEmpty);
    expect(toldChanges(), isEmpty);
  });

  test('imports.add creates the project, its checkout and the record — '
      'once', () async {
    final found = (await app.handleLater(const ImportsScan())).value;
    final one = found.singleWhere(
      (d) => d.sessions.any((s) => s.sessionId == 'sess-1'),
    );
    // Through the wire, as a client sends what it was shown.
    final answer = await app.handleJson({
      'id': 1,
      'kind': ImportsAdd.name,
      'arguments': ImportsAdd([one]).argumentsToJson(),
    });
    final summary = ImportSummary.fromJson(
      (answer['result'] as Map).cast<String, Object?>(),
    );
    expect(summary.projects, 1);
    expect(summary.repositories, 1);
    expect(summary.sessions, 1);

    final workspace = app.handle(const WorkspaceList()).value;
    expect(workspace.projects.single.root, here(projectDir));
    expect(workspace.repositories.single.path, here(projectDir));
    expect(imported().single.repositoryId, workspace.repositories.single.id);
    expect(toldChanges().whereType<ImportedChanged>(), hasLength(1));

    final again = (await app.handleLater(ImportsAdd([one]))).value;
    expect(again.isEmpty, isTrue);
    expect(app.handle(const WorkspaceList()).value.projects, hasLength(1));
    expect(imported(), hasLength(1));
  });
}
