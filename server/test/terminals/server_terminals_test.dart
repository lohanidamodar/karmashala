import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/pty/pty.dart' show PtyException;
import 'package:karmashala_host/src/terminals/listening_ports.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_launch/karmashala_launch.dart';
import 'package:test/test.dart';

/// The server's terminals (slice 5a): what it starts for a profile or an
/// agent — built with **its** OS, its shells and its vault — and what its
/// copy of each screen tells the clients.
void main() {
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late List<DataChange> told;
  var vault = <String, String>{};

  final wsl = ExecutionEnvironment(
    id: 'wsl:Ubuntu',
    createdAt: DateTime.utc(2026),
    name: 'Ubuntu',
    kind: EnvironmentKind.wsl,
    wslDistribution: 'Ubuntu',
  );
  final box = ExecutionEnvironment(
    id: 'ssh:box',
    createdAt: DateTime.utc(2026),
    name: 'box',
    kind: EnvironmentKind.ssh,
    sshHostId: 'box',
  );

  ServerTerminals terminalsOn({required bool windows}) => ServerTerminals(
    registry: registry,
    environments: () => [wsl, box],
    tell: told.addAll,
    overlay: () => vault,
    hostEnvironment: const {'SHELL': '/bin/zsh'},
    installedShells: () => const ['/bin/bash', '/bin/zsh'],
    windows: windows,
    settle: Duration.zero,
  );

  setUp(() {
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, hostname: 'this-mac');
    told = [];
    vault = {'API_TOKEN': 's3cret'};
  });

  tearDown(() async {
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
  });

  group('profiles', () {
    test('a POSIX server offers its own shells, login shell first', () {
      final profiles = terminalsOn(windows: false).profiles();
      expect(profiles.map((p) => p.id), ['posix:/bin/zsh', 'posix:/bin/bash']);
    });

    test('a Windows server offers PowerShell, cmd and each WSL distro — '
        'never SSH', () {
      final profiles = terminalsOn(windows: true).profiles();
      expect(profiles.map((p) => p.id), ['powershell', 'cmd', 'wsl:Ubuntu']);
    });
  });

  group('open', () {
    test('starts the profile\'s shell under the pane\'s session id, with the '
        'vault laid in and never recorded', () async {
      final terminals = terminalsOn(windows: false);
      final opened = terminals.open(
        const TerminalOpen(
          paneId: 'p1',
          profileId: 'posix:/bin/bash',
          workingDirectory: '/src/app',
          columns: 90,
          rows: 30,
        ),
      );
      expect(opened.sessionId, 'karmashala_local_p1');
      expect(opened.adopted, isFalse);
      expect(opened.title, 'bash');
      final request = launcher.started.single;
      expect(request.argv, ['/bin/bash']);
      expect(request.workingDirectory, '/src/app');
      expect(request.environment['API_TOKEN'], 's3cret');
      expect(request.environment['TERM'], 'xterm-256color');
      expect(request.unrecorded, {'API_TOKEN'});
      expect((request.columns, request.rows), (90, 30));
      expect(registry.find('karmashala_local_p1'), isNotNull);
      expect(told.single, isA<TerminalChanged>());
    });

    test('a pane opened again finds its running session, and starts '
        'nothing', () {
      final terminals = terminalsOn(windows: false);
      const request = TerminalOpen(paneId: 'p1', columns: 80, rows: 24);
      terminals.open(request);
      final again = terminals.open(request);
      expect(again.adopted, isTrue);
      expect(launcher.started, hasLength(1));
    });

    test('an ended record under the pane is replaced by a new process', () async {
      final terminals = terminalsOn(windows: false);
      const request = TerminalOpen(paneId: 'p1', columns: 80, rows: 24);
      terminals.open(request);
      launcher.handles.single.finish(0);
      await registry.find('karmashala_local_p1')!.ended;
      final again = terminals.open(request);
      expect(again.adopted, isFalse);
      expect(launcher.started, hasLength(2));
    });

    test('a Windows server reaches WSL through wsl.exe, with its own quoting '
        'and no host directory', () {
      terminalsOn(windows: true).open(
        const TerminalOpen(
          paneId: 'p2',
          environmentId: 'wsl:Ubuntu',
          workingDirectory: '/home/me/app',
          columns: 80,
          rows: 24,
          shellIntegration: true,
        ),
      );
      final request = launcher.started.single;
      expect(request.argv.take(5), [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/me/app',
      ]);
      expect(request.workingDirectory, isNull);
      expect(request.environment['WSLENV'], 'API_TOKEN/u');
    });

    test('the same WSL environment is refused by a server off Windows', () {
      expect(
        () => terminalsOn(windows: false).open(
          const TerminalOpen(
            paneId: 'p2',
            environmentId: 'wsl:Ubuntu',
            columns: 80,
            rows: 24,
          ),
        ),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.notFound,
          ),
        ),
      );
      expect(launcher.started, isEmpty);
    });

    test('an SSH environment, an unknown one and a foreign profile are '
        'refused in words', () {
      final terminals = terminalsOn(windows: false);
      for (final request in const [
        TerminalOpen(
          paneId: 'p',
          environmentId: 'ssh:box',
          columns: 80,
          rows: 24,
        ),
        TerminalOpen(paneId: 'p', environmentId: 'nope', columns: 80, rows: 24),
        TerminalOpen(
          paneId: 'p',
          profileId: 'powershell',
          columns: 80,
          rows: 24,
        ),
      ]) {
        expect(
          () => terminals.open(request),
          throwsA(isA<DataRefused>()),
          reason: request.argumentsToJson().toString(),
        );
      }
      expect(launcher.started, isEmpty);
    });

    test('an agent pane runs under its session row\'s id, the vault under '
        'its own session id', () {
      terminalsOn(windows: false).open(
        const TerminalOpen(
          paneId: 'p3',
          agentLaunch: AgentPaneLaunch(
            agentId: 'claudeCode',
            executable: '/usr/local/bin/claude',
            arguments: ['--session-id', 's1'],
            mcpArguments: ['--mcp-config', '/tmp/m.json'],
            removedEnvironment: {'ANTHROPIC_API_KEY'},
            workingDirectory: '/src/app',
            sessionId: 's1',
          ),
          columns: 80,
          rows: 24,
        ),
      );
      final request = launcher.started.single;
      expect(registry.find('karmashala_s1'), isNotNull);
      expect(request.argv, [
        '/usr/local/bin/claude',
        '--mcp-config',
        '/tmp/m.json',
        '--session-id',
        's1',
      ]);
      expect(request.environment[kSessionIdEnvironmentVariable], 's1');
      expect(request.environment['API_TOKEN'], 's3cret');
      expect(request.removedEnvironment, {
        ...kInheritedColourOptOuts,
        ...kInheritedAgentMarkers,
        'ANTHROPIC_API_KEY',
      });
    });

    test('a process that will not start is refused, and nothing is kept', () {
      launcher.failWith = const PtyException('no such shell');
      final terminals = terminalsOn(windows: false);
      expect(
        () => terminals.open(
          const TerminalOpen(paneId: 'p1', columns: 80, rows: 24),
        ),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.failed,
          ),
        ),
      );
      expect(terminals.records, isEmpty);
    });
  });

  group('what the screen says', () {
    test('title, directory, last command and exit are told', () async {
      final terminals = terminalsOn(windows: false);
      terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
      final pty = launcher.handles.single;
      told.clear();

      pty.emit(utf8.encode('\x1b]0;vim notes.md\x07'));
      pty.emit(utf8.encode('\x1b]7;file://this-mac/src/app\x07'));
      pty.emit(utf8.encode('\x1b]133;A\x07\$ \x1b]133;B\x07make test\r\n'));
      pty.emit(utf8.encode('\x1b]133;C\x07running\r\n\x1b]133;D;2\x07'));
      await pumpEventQueue();

      final record = terminals.records.single;
      expect(record.title, 'vim notes.md');
      expect(record.workingDirectory, '/src/app');
      expect(record.lastCommand, 'make test');
      expect(record.lastCommandExitCode, 2);
      expect(told.whereType<TerminalChanged>(), isNotEmpty);

      told.clear();
      pty.finish(0);
      await registry.find('karmashala_local_p1')!.ended;
      await pumpEventQueue();
      final ended = terminals.records.single;
      expect(ended.isLive, isFalse);
      expect(ended.exitCode, 0);
      expect(
        told.whereType<TerminalChanged>().last.terminal.exitCode,
        0,
      );
    });

    test('a directory another machine reports is not one here', () async {
      final terminals = terminalsOn(windows: false);
      terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
      launcher.handles.single.emit(
        utf8.encode('\x1b]7;file://elsewhere/etc\x07'),
      );
      await pumpEventQueue();
      expect(terminals.records.single.workingDirectory, isNull);
    });

    test('a rename wins over the program\'s title until it is cleared', () async {
      final terminals = terminalsOn(windows: false);
      final opened = terminals.open(
        const TerminalOpen(paneId: 'p1', columns: 80, rows: 24),
      );
      final pty = launcher.handles.single;
      terminals.rename(opened.sessionId, 'build');
      pty.emit(utf8.encode('\x1b]0;zsh\x07'));
      await pumpEventQueue();
      expect(terminals.records.single.title, 'build');
      terminals.rename(opened.sessionId, '');
      expect(terminals.records.single.title, 'zsh');
      expect(
        () => terminals.rename('karmashala_local_nope', 'x'),
        throwsA(isA<DataRefused>()),
      );
    });
  });

  test('close ends the process, forgets the record and says so', () async {
    final terminals = terminalsOn(windows: false);
    final opened = terminals.open(
      const TerminalOpen(paneId: 'p1', columns: 80, rows: 24),
    );
    final pty = launcher.handles.single;
    told.clear();
    final closing = terminals.close(opened.sessionId);
    await pumpEventQueue();
    expect(pty.signals, contains(15));
    pty.finish(143);
    await closing;
    expect(registry.find(opened.sessionId), isNull);
    expect(terminals.records, isEmpty);
    expect(told.whereType<TerminalRemoved>().single.sessionId, opened.sessionId);
    expect(
      () => terminals.close(opened.sessionId),
      throwsA(isA<DataRefused>()),
    );
  });

  test('a subscriber is greeted with every terminal', () {
    final terminals = terminalsOn(windows: false)
      ..open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24))
      ..open(const TerminalOpen(paneId: 'p2', columns: 80, rows: 24));
    expect(
      terminals.greeting().whereType<TerminalChanged>().map(
        (c) => c.terminal.paneId,
      ),
      ['p1', 'p2'],
    );
  });

  test('running lists each pane under its machine, the server by its own '
      'ports, and stops only what a pane started', () async {
    final ran = <List<String>>[];
    var shell = 0;
    final terminals = ServerTerminals(
      registry: registry,
      environments: () => [wsl, box],
      tell: told.addAll,
      overlay: () => vault,
      windows: true,
      settle: Duration.zero,
      ports: ListeningPortProbe(
        windows: true,
        run: (executable, arguments) async {
          ran.add([executable, ...arguments]);
          return ProcessResult(
            1,
            0,
            'P $pid 1 1 dart.exe\n'
            'P $shell $pid 2 wsl.exe\n'
            'P 900 $shell 3 node.exe\n'
            'L 47821 $pid 127.0.0.1\n',
            '',
          );
        },
      ),
    )..serverPorts = () => const {47821: 'MCP endpoint'};
    await terminals.handle(
      const TerminalOpen(
        paneId: 'p2',
        environmentId: 'wsl:Ubuntu',
        columns: 80,
        rows: 24,
      ),
    );
    shell = launcher.handles.single.pid;

    final reading =
        await terminals.handle(const TerminalsRunning()) as RunningReading;
    expect(reading.serverPid, pid);
    final server = reading.processes.firstWhere(
      (p) => p.role == RunningRole.server,
    );
    expect(server.ports.single.label, 'MCP endpoint');
    final root = reading.processes.firstWhere((p) => p.pid == shell);
    expect(root.environmentId, 'wsl:Ubuntu');
    expect(root.paneId, 'p2');
    expect(reading.processes.firstWhere((p) => p.pid == 900).stoppable, isTrue);

    await expectLater(
      terminals.handle(TerminalStopProcess(shell)),
      throwsA(isA<DataRefused>()),
    );
    await terminals.handle(const TerminalStopProcess(900));
    expect(ran.last, ['taskkill', '/PID', '900', '/T', '/F']);
  });

  test('the work answers through the data port', () async {
    final terminals = terminalsOn(windows: false);
    final opened =
        await terminals.handle(
              const TerminalOpen(paneId: 'p1', columns: 80, rows: 24),
            )
            as TerminalOpened;
    final listed = await terminals.handle(const TerminalsList()) as List;
    expect(listed.cast<TerminalRecord>().single.sessionId, opened.sessionId);
    expect(
      await terminals.handle(const TerminalsProfiles()),
      isA<List<TerminalProfile>>(),
    );
  });
}
