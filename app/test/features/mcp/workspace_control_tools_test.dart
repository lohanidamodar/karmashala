import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// The workspace tools, over the endpoint, with git answering the way a test
/// tells it to.
///
/// The rule these are really about is the last one: **a reading Karmashala
/// could not take is reported as "not recorded", never as zero.** A model that
/// reads `unpushed: 0` from a failed git call concludes the branch is pushed.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;
  late FakeCommandRunner git;

  /// `git worktree list --porcelain` for a main clone and one worktree.
  const worktreePorcelain = '''
worktree C:/src/demo/app
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree C:/src/demo/app-feature
HEAD 2222222222222222222222222222222222222222
branch refs/heads/feature/login
''';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_workspace_tools_');
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    final fake = FakeDataServer()..mirrorInto(db);
    fake.projectRows.insert(project());
    fake.repositoryRows.insert(repository());
    fake.repositoryRows.insert(
      repository(
        id: 'r2',
        name: 'app-feature',
        path: r'C:\src\demo\app-feature',
      ),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', title: 'Work'));

    git = FakeCommandRunner(
      responder: (request) {
        // `git -C <path> worktree list --porcelain`: the subcommand is not
        // argument zero, because GitService puts `-C <repo>` in front of it.
        final args = request.arguments;
        if (args.contains('worktree') && args.contains('list')) {
          return const CommandResult(
            exitCode: 0,
            stdout: worktreePorcelain,
            stderr: '',
          );
        }
        // Everything else fails, which is how a reading becomes unknown.
        return const CommandResult(
          exitCode: 128,
          stdout: '',
          stderr: 'fatal: not a git repository',
        );
      },
    );

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await fake.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
        probeGateProvider.overrideWithValue(headlessProbeGate),
        gitFilesProvider.overrideWithValue(noGitFiles),
      ],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<({bool isError, String text, Object? structured})> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
    String? asSession,
  ]) async {
    final json =
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;
    final credential = asSession == null
        ? json['mcpToken']! as String
        : server.callers.tokenFor(asSession);
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp/$credential'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, Object?>{'name': name, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      final result =
          (jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, Object?>)['result']!
              as Map<String, Object?>;
      final content =
          (result['content']! as List<Object?>).first as Map<String, Object?>;
      return (
        isError: result['isError'] == true,
        text: content['text']! as String,
        structured: result['structuredContent'],
      );
    } finally {
      client.close(force: true);
    }
  }

  group('list_checkouts', () {
    test('names every checkout with the branch git reported', () async {
      final structured =
          (await callTool('list_checkouts', {'projectId': 'p1'})).structured!
              as Map<String, Object?>;
      final checkouts = (structured['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();

      expect(checkouts, hasLength(2));
      expect(checkouts.first['repositoryId'], 'r1');
      expect(checkouts.first['branch'], 'main');
      expect(checkouts.first['isWorktree'], isFalse);
      expect(checkouts.last['branch'], 'feature/login');
      expect(
        checkouts.last['isWorktree'],
        isTrue,
        reason: 'git lists the main worktree first; the rest are worktrees',
      );
    });

    test('a branch git could not report reads "not recorded"', () async {
      git.responder = (_) => const CommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: not a git repository',
      );

      final structured =
          (await callTool('list_checkouts', {'projectId': 'p1'})).structured!
              as Map<String, Object?>;
      final checkouts = structured['checkouts']! as List<Object?>;

      // The checkouts are still listed — we know they exist. What we do not
      // know is what branch they are on, and that is said rather than guessed.
      expect(checkouts, hasLength(2));
      for (final checkout in checkouts.cast<Map<String, Object?>>()) {
        expect(checkout['branch'], 'not recorded');
        expect(checkout['isWorktree'], isNull);
      }
    });

    test('an unknown project is an error', () async {
      final result = await callTool('list_checkouts', {'projectId': 'ghost'});
      expect(result.isError, isTrue);
      expect(result.text, contains('ghost'));
    });
  });

  group('select_checkout', () {
    test('the app\'s selection actually moves', () async {
      expect(container.read(selectedRepositoryIdProvider), isNull);

      final result = await callTool('select_checkout', {'repositoryId': 'r2'});

      expect(result.isError, isFalse);
      expect(container.read(selectedRepositoryIdProvider), 'r2');
      expect(container.read(selectedProjectIdProvider), 'p1');
    });

    test('an unknown checkout changes nothing', () async {
      final result = await callTool('select_checkout', {
        'repositoryId': 'ghost',
      });
      expect(result.isError, isTrue);
      expect(container.read(selectedRepositoryIdProvider), isNull);
    });
  });

  group('delivery_status', () {
    test('unknown readings say so instead of reading as zero', () async {
      final structured =
          (await callTool('delivery_status', {'sessionId': 's1'})).structured!
              as Map<String, Object?>;

      // Every one of these is null at the source because git failed. Zero
      // would mean "nothing outstanding", which is the opposite of true here.
      expect(structured['dirtyFiles'], 'not recorded');
      expect(structured['unpushed'], 'not recorded');
      expect(structured['aheadOfBase'], 'not recorded');
      expect(structured['behindBase'], 'not recorded');
      expect(structured['branch'], 'not recorded');
      expect(structured['pullRequest'], startsWith('not recorded'));
    });

    test('offers the same actions the delivery strip would', () async {
      final structured =
          (await callTool('delivery_status', {'sessionId': 's1'})).structured!
              as Map<String, Object?>;
      final actions = (structured['actions']! as List<Object?>)
          .cast<Map<String, Object?>>();

      expect(actions, isNotEmpty);
      for (final action in actions) {
        expect(action['label'], isA<String>());
        // An unavailable action carries its reason, so an agent is never left
        // guessing why it cannot push.
        if (action['available'] == false) {
          expect(action['unavailableBecause'], isA<String>());
        }
      }
      expect(structured['stage'], isA<String>());
    });

    test('defaults to the calling session', () async {
      final structured =
          (await callTool('delivery_status', const {}, 's1')).structured!
              as Map<String, Object?>;
      expect(structured['sessionId'], 's1');
      expect(structured['title'], 'Work');
    });

    test('an unattributed caller must name a session', () async {
      final result = await callTool('delivery_status');
      expect(result.isError, isTrue);
      expect(result.text, contains('not running inside a session'));
    });
  });

  group('project_rescan', () {
    test('an unknown project is an error, not an empty success', () async {
      final result = await callTool('project_rescan', {'projectId': 'ghost'});
      expect(result.isError, isTrue);
    });
  });
}
