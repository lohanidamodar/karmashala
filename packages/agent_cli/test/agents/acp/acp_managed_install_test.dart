import 'package:agent_cli/src/agents/acp/acp_managed_install.dart';
import 'package:agent_cli/src/agents/data/agent_discovery_service.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/environments/environment_kind.dart';
import 'package:agent_cli/src/process/command_runner.dart';
import 'package:test/test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');
const _notFound = CommandResult(exitCode: 1, stdout: '', stderr: '');

/// An ACP agent the registry ships as an archive is found where Karmashala
/// installs it — `~/karmashala/acp/<registry id>/<version>/` — when it is
/// not on PATH, newest version first, with the folder's version.
void main() {
  group('the managed folder', () {
    test('is spelled for each platform', () {
      expect(
        acpManagedDirectory(EnvironmentKind.wsl, 'antigravity-acp', '1.3.0'),
        'karmashala/acp/antigravity-acp/1.3.0',
      );
      expect(
        acpManagedDirectory(
          EnvironmentKind.windowsNative,
          'antigravity-acp',
          '1.3.0',
        ),
        r'karmashala\acp\antigravity-acp\1.3.0',
      );
    });

    test('is listed through the login shell on POSIX, with no variable', () {
      final request = acpManagedLocateRequest(
        EnvironmentKind.wsl,
        'antigravity-acp',
        ['agy_acp_server.par', 'agy_acp_server'],
      )!;
      expect(request.executable, 'bash');
      expect(request.arguments.first, '-lc');
      expect(
        request.arguments.last,
        'ls -1 ~/karmashala/acp/antigravity-acp/*/agy_acp_server.par '
        '~/karmashala/acp/antigravity-acp/*/agy_acp_server 2>/dev/null',
      );
      // A WSL login shell parses the line before bash does; a `$` would be
      // expanded there, so none is used.
      expect(request.arguments.last, isNot(contains(r'$')));
    });

    test('is searched with where /r under the profile on Windows', () {
      final request = acpManagedLocateRequest(
        EnvironmentKind.windowsNative,
        'antigravity-acp',
        ['agy_acp_server.exe'],
        hostEnvironment: {'USERPROFILE': r'C:\Users\me'},
      )!;
      expect(request.executable, 'where');
      expect(request.arguments, [
        '/r',
        r'C:\Users\me\karmashala\acp\antigravity-acp',
        'agy_acp_server.exe',
      ]);
      expect(
        acpManagedLocateRequest(EnvironmentKind.windowsNative, 'x', [
          'x.exe',
        ], hostEnvironment: const {}),
        isNull,
      );
      expect(acpManagedLocateRequest(EnvironmentKind.wsl, 'x', []), isNull);
    });
  });

  group('newestAcpManagedInstall', () {
    test('takes the newest version folder, numerically', () {
      expect(
        newestAcpManagedInstall(
          '/home/me/karmashala/acp/a/1.9.0/agy\n'
          '/home/me/karmashala/acp/a/1.10.0/agy\n'
          '/home/me/karmashala/acp/a/1.3.0/agy\n',
        ),
        (path: '/home/me/karmashala/acp/a/1.10.0/agy', version: '1.10.0'),
      );
      expect(
        newestAcpManagedInstall(
          'C:\\Users\\me\\karmashala\\acp\\a\\1.3.0\\agy.exe\r\n',
        ),
        (path: r'C:\Users\me\karmashala\acp\a\1.3.0\agy.exe', version: '1.3.0'),
      );
      expect(newestAcpManagedInstall(''), isNull);
      expect(newestAcpManagedInstall('  \n'), isNull);
    });

    test('version order', () {
      expect(compareVersionStrings('1.10.0', '1.9.3'), greaterThan(0));
      expect(compareVersionStrings('1.3.0', '1.3.0'), 0);
      expect(compareVersionStrings('1.3', '1.3.0'), lessThan(0));
      expect(compareVersionStrings('1.3.0-beta', '1.3.0'), lessThan(0));
      expect(compareVersionStrings('latest', '1.3.0'), lessThan(0));
    });
  });

  group('discovery', () {
    test('finds the managed install when PATH has nothing, with the folder\'s '
        'version and no --version spawn', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          final script = req.arguments.length > 1 ? req.arguments.last : '';
          if (script.startsWith('ls -1 ~/karmashala/acp/antigravity-acp/')) {
            return _ok(
              '/home/me/karmashala/acp/antigravity-acp/1.2.0/agy_acp_server.par\n'
              '/home/me/karmashala/acp/antigravity-acp/1.3.0/agy_acp_server.par\n',
            );
          }
          return _notFound;
        },
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover(agentIds: {AgentIds.antigravityAcp});
      final agent = found.single;
      expect(agent.agentId, AgentIds.antigravityAcp);
      expect(
        agent.executable.path,
        '/home/me/karmashala/acp/antigravity-acp/1.3.0/agy_acp_server.par',
      );
      expect(agent.version, '1.3.0');
      expect(agent.versionReadAt, testTime);
      expect(agent.leadingArguments, isEmpty);
      expect(
        runner.requests.where((r) => r.arguments.contains('--version')),
        isEmpty,
      );
    });

    test('a binary on PATH wins over the managed folder', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          if (req.executable == 'where') {
            return req.arguments.first == 'agy_acp_server.exe'
                ? _ok('C:\\tools\\agy_acp_server.exe\r\n')
                : _notFound;
          }
          return _notFound;
        },
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {'USERPROFILE': r'C:\Users\me'},
      ).discover(agentIds: {AgentIds.antigravityAcp});
      expect(found.single.executable.path, r'C:\tools\agy_acp_server.exe');
      expect(found.single.version, isNull);
      expect(
        runner.requests.where((r) => r.arguments.first == '/r'),
        isEmpty,
        reason: 'the managed folder is asked only when PATH has nothing',
      );
    });

    test(
      'on Windows the managed folder is searched under the profile',
      () async {
        final runner = FakeCommandRunner(
          responder: (req) {
            if (req.executable == 'where' && req.arguments.first == '/r') {
              return _ok(
                'C:\\Users\\me\\karmashala\\acp\\antigravity-acp\\1.3.0\\'
                'agy_acp_server.exe\r\n',
              );
            }
            return _notFound;
          },
        );
        final found = await AgentDiscoveryService(
          runner: runner,
          environment: windowsEnv(),
          ids: SequentialIdGenerator(),
          clock: FixedClock(testTime),
          hostEnvironment: const {'USERPROFILE': r'C:\Users\me'},
        ).discover(agentIds: {AgentIds.antigravityAcp});
        expect(
          found.single.executable.path,
          r'C:\Users\me\karmashala\acp\antigravity-acp\1.3.0\agy_acp_server.exe',
        );
        expect(found.single.version, '1.3.0');
      },
    );

    test(
      'with nothing installed anywhere the agent is simply missing',
      () async {
        // The distribution answers the liveness probe; nothing else is found.
        final runner = FakeCommandRunner(
          responder: (req) =>
              req.arguments.last == 'exit 0' ? _ok('') : _notFound,
        );
        final probe = await AgentDiscoveryService(
          runner: runner,
          environment: wslEnv(),
          ids: SequentialIdGenerator(),
          clock: FixedClock(testTime),
          hostEnvironment: const {},
        ).probeEnvironment(agentIds: {AgentIds.antigravityAcp});
        expect(probe.found, isEmpty);
        expect(probe.missingAgentIds, [AgentIds.antigravityAcp]);
        // No npm package to fall back to, so npx is never asked for.
        expect(
          runner.requests.where((r) => r.arguments.last.contains('npx')),
          isEmpty,
        );
      },
    );

    test('an agent that names no registry entry never looks there', () async {
      final runner = FakeCommandRunner(responder: (_) => _notFound);
      await AgentDiscoveryService(
        runner: runner,
        environment: wslEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        hostEnvironment: const {},
      ).discover(agentIds: {AgentIds.claudeCode, AgentIds.grok});
      expect(
        runner.requests.where(
          (r) => r.arguments.last.contains('karmashala/acp'),
        ),
        isEmpty,
      );
    });
  });
}
