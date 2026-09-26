import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// `select_checkout`, over the endpoint: the one workspace tool that moves
/// this app's own screen. `list_checkouts`, `project_rescan` and
/// `delivery_status` are the server's now (`server/test/mcp/tools/
/// workspace_tool_set_test.dart`).
void main() {
  late Directory tmp;
  late TestMachine db;
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
    db = TestMachine();
    final fake = FakeDataServer()..runsOn(db);
    fake.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    fake.projectRows.insert(project());
    fake.repositoryRows.insert(repository());
    fake.repositoryRows.insert(
      repository(
        id: 'r2',
        name: 'app-feature',
        path: r'C:\src\demo\app-feature',
      ),
    );
    fake.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(session(id: 's1', title: 'Work'));

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
}
