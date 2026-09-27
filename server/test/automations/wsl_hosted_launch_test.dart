import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/automations/hosted_check_runner.dart';
import 'package:karmashala_host/src/pty/environment_spawn.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Slice 5a: a Windows server's WSL distributions are its own — agents,
/// checks and worktree setup run there through `wsl.exe`, never as a
/// Windows process pointed at a Linux path.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);

  ExecutionEnvironment env(EnvironmentKind kind, {String? distro}) =>
      ExecutionEnvironment(
        id: kind.name,
        kind: kind,
        name: kind.name,
        wslDistribution: distro,
        createdAt: t0,
      );

  group('DaemonCheckoutFacts.isHere', () {
    late AppDatabase database;
    setUp(() => database = AppDatabase.memory());
    tearDown(() => database.close());

    test('a WSL distribution is here on a Windows server only', () {
      final wsl = env(EnvironmentKind.wsl, distro: 'Ubuntu');
      expect(
        DaemonCheckoutFacts(CheckoutRows(database), windows: true).isHere(wsl),
        isTrue,
      );
      expect(
        DaemonCheckoutFacts(CheckoutRows(database), windows: false).isHere(wsl),
        isFalse,
      );
    });

    test('an SSH box is never here', () {
      final ssh = env(EnvironmentKind.ssh);
      for (final windows in [true, false]) {
        expect(
          DaemonCheckoutFacts(
            CheckoutRows(database),
            windows: windows,
          ).isHere(ssh),
          isFalse,
        );
      }
    });
  });

  group('spawnRequestIn', () {
    test('this machine: the argv as it is, in its directory', () {
      final request = spawnRequestIn(
        null,
        argv: ['make', 'setup'],
        directory: '/src/app',
        variables: {'K': 'v'},
      );
      expect(request.argv, ['make', 'setup']);
      expect(request.workingDirectory, '/src/app');
      expect(request.environment, {'TERM': 'xterm-256color', 'K': 'v'});
      expect(request.environment.containsKey('WSLENV'), isFalse);
    });

    test('WSL: through wsl.exe with --cd, no host directory, variables named '
        'in WSLENV and never in the command line', () {
      final request = spawnRequestIn(
        env(EnvironmentKind.wsl, distro: 'Ubuntu'),
        argv: ['/usr/bin/claude', '--resume', 'x'],
        directory: '/home/u/app',
        variables: {'KARMASHALA_SESSION_ID': 's1'},
        removed: {'ANTHROPIC_API_KEY'},
      );
      expect(request.argv, [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/u/app',
        '--',
        '/usr/bin/claude',
        '--resume',
        'x',
      ]);
      expect(request.workingDirectory, isNull);
      expect(request.environment['KARMASHALA_SESSION_ID'], 's1');
      expect(request.environment['WSLENV'], 'KARMASHALA_SESSION_ID/u');
      expect(request.argv.join(' '), isNot(contains('s1')));
      expect(request.removedEnvironment, {'ANTHROPIC_API_KEY'});
    });
  });

  group('in a WSL checkout', () {
    late AppDatabase database;
    late SessionRegistry registry;
    late FakePtyLauncher pty;

    setUp(() {
      database = AppDatabase.memory();
      database.execute('PRAGMA foreign_keys = OFF;');
      database.execute(
        'INSERT INTO execution_environments (id, kind, name, '
        'wsl_distribution, created_at) VALUES (?, ?, ?, ?, ?);',
        ['wsl1', 'wsl', 'Ubuntu', 'Ubuntu', t0.toIso8601String()],
      );
      database.execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, '
        'path, created_at) VALUES (?, ?, ?, ?, ?, ?);',
        ['r2', 'p2', 'far', 'wsl1', '/home/u/far', '$t0'],
      );
      database.execute(
        'INSERT INTO agent_installations (id, agent_kind, environment_id, '
        'executable_path, created_at, executable_by_user) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        ['a2', AgentIds.claudeCode, 'wsl1', '/usr/bin/claude', '$t0', 1],
      );
      pty = FakePtyLauncher();
      registry = SessionRegistry(launcher: pty);
    });

    tearDown(() async {
      for (final handle in pty.handles) {
        handle.finish(0);
      }
      await registry.shutdown();
      database.close();
    });

    test('an agent is started through wsl.exe, its session id in WSLENV and '
        'no tools a WSL agent could not reach', () async {
      final rows = CheckoutRows(database);
      final launcher = HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
        now: () => t0,
        newId: () => 's1',
        hostEnvironment: const {},
        environmentOf: rows.environment,
      );
      final session = await launcher.start(
        HostedLaunch(
          repository: rows.repository('r2')!,
          installation: rows.installation('a2')!,
          title: 'far',
        ),
      );
      final started = pty.started.single;
      expect(started.argv.take(6), [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/u/far',
        '--',
      ]);
      expect(started.argv[6], '/usr/bin/claude');
      expect(started.workingDirectory, isNull);
      expect(started.environment['KARMASHALA_SESSION_ID'], session.id);
      expect(started.environment['WSLENV'], 'KARMASHALA_SESSION_ID/u');
      expect(started.argv.any((a) => a.contains('mcp')), isFalse);
    });

    test('a check runs through wsl.exe in its checkout', () async {
      final runner = HostedCheckRunner(
        registry: registry,
        newId: () => 'c1',
        environmentOf: CheckoutRows(database).environment,
      );
      final execution = runner.execute(
        ProjectCheck(
          id: 'k1',
          repositoryId: 'r2',
          name: 'test',
          command: const ['flutter', 'test'],
          createdAt: t0,
        ),
        directory: const EnvironmentPath(
          environmentId: 'wsl1',
          path: '/home/u/far',
        ),
        title: 'test',
      );
      await Future<void>.delayed(Duration.zero);
      expect(pty.started.single.argv, [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/u/far',
        '--',
        'flutter',
        'test',
      ]);
      pty.handles.single.finish(0);
      await execution;
    });
  });
}
