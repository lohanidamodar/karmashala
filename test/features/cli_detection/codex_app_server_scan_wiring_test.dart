import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_server_client.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_server_launch.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_server_reader.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_store_reader.dart';
import 'package:karmashala/src/features/cli_detection/data/store_scan_worker.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_codex_app_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// **How the app-server reaches the worker isolate.**
///
/// The scan runs on `karmashala.store-scan`, where there are no providers and
/// no DAOs — and a live `Process` cannot cross an isolate boundary, so the
/// spawn has to happen over there. The answer is a resolution on the main
/// isolate carried across as plain data, and these cases pin both halves: that
/// `CliStoreLocator` attaches it, and that it survives the port.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_wiring_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A `.codex` store with one rollout the walk can find.
  String codexStore(String id) {
    final home = p.join(tmp.path, '.codex');
    File(p.join(home, 'sessions', '2026', '09', '05', 'rollout-$id.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"timestamp":"2026-09-05T07:57:55.000Z","type":"session_meta",'
        '"payload":{"id":"$id","cwd":"/w",'
        '"timestamp":"2026-09-05T07:57:55.000Z"}}\n',
      );
    return home;
  }

  FakeCommandRunnerFactory homeIs(String home) => FakeCommandRunnerFactory(
    fallback: FakeCommandRunner(
      responder: (_) => CommandResult(exitCode: 0, stdout: home, stderr: ''),
    ),
  );

  group('CliStoreLocator', () {
    late AppDatabase db;
    setUp(() {
      db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      addTearDown(db.close);
    });

    test('a located store carries the Codex it can ask', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          agentId: AgentIds.codex,
          path: r'C:\Users\me\.bin\codex.exe',
        ),
      );

      final store = (await CliStoreLocator(
        runnerFactory: homeIs('/home/me'),
        installations: AgentInstallationDao(db),
        environment: const {'USERPROFILE': r'C:\Users\me'},
      ).locate([windowsEnv()])).single;

      expect(store.codexAppServer!.executable, r'C:\Users\me\.bin\codex.exe');
      expect(store.codexAppServer!.environment.id, 'windows');
    });

    test('no Codex installed means no app-server to carry', () async {
      AgentInstallationDao(db).insert(agentInstallation());

      final store = (await CliStoreLocator(
        runnerFactory: homeIs('/home/me'),
        installations: AgentInstallationDao(db),
        environment: const {'USERPROFILE': r'C:\Users\me'},
      ).locate([windowsEnv()])).single;

      expect(store.codexAppServer, isNull);
      expect(store.codexHome, isNotNull, reason: 'the store is still walked');
    });

    test('a locator with no DAO walks every store, as it always did', () async {
      final store = (await CliStoreLocator(
        runnerFactory: homeIs('/home/me'),
        environment: const {'USERPROFILE': r'C:\Users\me'},
      ).locate([windowsEnv()])).single;

      expect(store.codexAppServer, isNull);
    });
  });

  test('a scan reads Codex through the protocol, end to end', () async {
    final home = codexStore('u1');
    final server = FakeCodexAppServer.withThreads([
      {
        'id': 'u1',
        'name': 'from the server',
        'preview': 'the real question',
        'cwd': '/w',
        'path': p.join(
          home,
          'sessions',
          '2026',
          '09',
          '05',
          'rollout-u1.jsonl',
        ),
        'createdAt': 1788574375,
        'updatedAt': 1788585458,
      },
    ], codexHome: home);
    final detection = CliDetectionService(
      codexAppServerReader: CodexAppServerReader(
        fallback: CodexStoreReader(cache: CodexRolloutCache()),
        openClient: (launch, expectedCodexHome) => CodexAppServerClient(
          connect: () async => server,
          timeout: const Duration(seconds: 5),
          expectedCodexHome: expectedCodexHome,
        ),
      ),
    );
    addTearDown(detection.codexAppServerReader.close);

    final chunks = await InlineStoreScanRunner(detection: detection)
        .scan(
          StoreScanRequest(
            stores: [
              CliStore(
                environmentId: 'windows',
                homesByAgentId: {AgentIds.codex: home},
                codexAppServer: CodexAppServerLaunch(
                  environment: windowsEnv(),
                  executable: r'C:\codex.exe',
                ),
              ),
            ],
          ),
        )
        .toList();

    final session = chunks.single.sessions.single;
    expect(session.title, 'from the server');
    expect(session.preview, 'the real question');
    expect(detection.codexAppServerReader.fallbacksServed, 0);
  });

  test('the launch crosses to the worker isolate as plain data', () async {
    // A `SendPort` refuses anything it cannot copy, so this case is the whole
    // proof that the resolution can happen on the isolate with the DAOs while
    // the spawn happens on the one that scans. The executable named here does
    // not exist, so the worker's attempt fails and the walk answers — which is
    // also the fallback working across the boundary.
    final home = codexStore('u2');
    final runner = IsolateStoreScanRunner();
    addTearDown(runner.shutdown);

    final chunks = await runner
        .scan(
          StoreScanRequest(
            stores: [
              CliStore(
                environmentId: 'windows',
                homesByAgentId: {AgentIds.codex: home},
                codexAppServer: CodexAppServerLaunch(
                  environment: windowsEnv(),
                  executable: p.join(tmp.path, 'no-such-codex'),
                ),
              ),
            ],
          ),
        )
        .toList();

    expect(chunks.single.isolate, kStoreScanIsolateName);
    expect(chunks.single.sessions.single.sessionId, 'u2');
  });
}
