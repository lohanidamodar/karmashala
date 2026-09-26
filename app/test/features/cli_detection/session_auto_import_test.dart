import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/session_auto_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/store_scan_worker.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';

/// **Which sessions a repository takes, and which the Claude store is asked
/// for.**
///
/// Matching is exact-path, which is the owner's own rule: *"sub folder sessions
/// will become their own project"*. A conversation that ran in a subfolder is
/// its own project, not the parent's, and this pins that it stays that way.
void main() {
  late AppDatabase db;
  late List<StoreScanRequest> asked;
  late FakeDataServer server;
  late SessionsData sessions;
  late ImportedSessionsData imported;

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  SessionAutoImportService serviceFor(List<DetectedSession> found) {
    asked = [];
    return SessionAutoImportService(
      locator: FixedLocator([
        const CliStore(
          environmentId: 'windows',
          homesByAgentId: {AgentIds.claudeCode: r'C:\store\.claude'},
        ),
      ]),
      scan: (request) {
        asked.add(request);
        return Stream.value(
          StoreScanChunk(
            agentId: AgentIds.claudeCode,
            environmentId: 'windows',
            sessions: found,
            isolate: 'test',
          ),
        );
      },
      environmentDao: ExecutionEnvironmentDao(db),
      importedSessionDao: imported,
      sessionDao: sessions,
      ids: SequentialIdGenerator('i-'),
      clock: FixedClock(testTime),
    );
  }

  DetectedSession sessionIn(String cwd, String id) => DetectedSession(
    cli: AgentIds.claudeCode,
    sessionId: id,
    cwd: at(cwd),
    filePath: 'C:\\store\\$id.jsonl',
    storeHome: r'C:\store\.claude',
  );

  setUp(() async {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server = FakeDataServer()..mirrorInto(db);
    server.projectRows.insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    server.repositoryRows.insert(
      Repository(
        id: 'r1',
        projectId: 'p1',
        name: 'hub',
        path: at(r'C:\hub'),
        createdAt: testTime,
      ),
    );
    final client = await server.connect();
    sessions = SessionsData(client);
    imported = ImportedSessionsData(client, sessions);
  });
  tearDown(() => db.close());

  List<Repository> repos() => server.repositoryRows.getAll();

  test('a session in the repository itself is imported', () async {
    final service = serviceFor([sessionIn(r'C:\hub', 's1')]);
    expect((await service.importForRepositories(repos())).sessions, 1);
  });

  test('a session in a subfolder belongs to its own project, not the '
      'repository above it', () async {
    final service = serviceFor([
      sessionIn(r'C:\hub\packages\api', 's-sub'),
      sessionIn(r'C:\hub', 's-root'),
    ]);

    expect(
      (await service.importForRepositories(repos())).sessions,
      1,
      reason: 'only the one that ran in the repository itself',
    );
    expect(
      imported.getByRepository('r1').map((s) => s.externalId),
      ['s-root'],
    );
  });

  test('the Claude store is asked only for the directories the repositories '
      'encode to', () async {
    final service = serviceFor(const []);
    await service.importForRepositories(repos());

    final names = asked.single.workingDirectories!
        .map(const ClaudeCodeStore().directoryNameFor)
        .toSet();
    expect(names, contains('c--hub'));
    expect(
      names,
      hasLength(2),
      reason: 'the Windows spelling and its /mnt/c form, both lowercased',
    );
  });

  test(
    'narrowing is refusable, for a store that encodes paths otherwise',
    () async {
      asked = [];
      final service = SessionAutoImportService(
        locator: FixedLocator(const []),
        scan: (request) {
          asked.add(request);
          return const Stream.empty();
        },
        environmentDao: ExecutionEnvironmentDao(db),
        importedSessionDao: imported,
        sessionDao: sessions,
        ids: SequentialIdGenerator('i-'),
        clock: FixedClock(testTime),
        narrowByDirectory: false,
      );
      await service.importForRepositories(repos());
      expect(asked.single.workingDirectories, isNull);
    },
  );
}
