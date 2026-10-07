import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/terminals/linux_running.dart';
import 'package:karmashala_host/src/terminals/listening_ports.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:test/test.dart';

import 'package:karmashala_host/src/pty/fake_pty.dart';

/// One look inside a distribution: an agent (411, under its wrapper 410) of
/// session `s-wsl` runs `npm run dev`, whose vite (421) holds 3000 and whose
/// esbuild (422) has an environment this user cannot read; the agent's
/// python (430) holds 8000. postgres (500) and a node of a session that is
/// not this server's (510) listen too, as does Karmashala's own host (600),
/// and something on 22 whose process is not this user's. 700 is the probe.
const _listing = '''
@@self 700
@@ps
    1     0 /init
  400     1 /init
  401   400 /init
  410   401 /bin/bash -l
  411   410 node /home/u/.local/bin/claude
  420   411 npm run dev
  421   420 node /work/site/node_modules/.bin/vite --port 3000
  422   421 /work/site/node_modules/@esbuild/linux-x64/bin/esbuild --service
  430   411 python3 -m http.server 8000
  500     1 postgres -D /var/lib/postgres
  510     1 node other.js
  600   401 /home/u/.karmashala/host/bin/karmashala_host serve
  700   401 sh -s
  701   700 ps -A -o pid=,ppid=,args=
@@comm
    1 init
  400 init
  401 init
  410 bash
  411 node
  420 npm run dev
  421 node
  422 esbuild
  430 python3
  500 postgres
  510 node
  600 karmashala_host
  700 sh
  701 ps
@@env
/proc/410/environ:KARMASHALA_SESSION_ID=s-wsl
/proc/411/environ:KARMASHALA_SESSION_ID=s-wsl
/proc/420/environ:KARMASHALA_SESSION_ID=s-wsl
/proc/421/environ:KARMASHALA_SESSION_ID=s-wsl
/proc/430/environ:KARMASHALA_SESSION_ID=s-wsl
/proc/510/environ:KARMASHALA_SESSION_ID=s-elsewhere
/proc/700/environ:KARMASHALA_SESSION_ID=s-wsl
@@ss
LISTEN 0      511          0.0.0.0:3000      0.0.0.0:*    users:(("node",pid=421,fd=20))
LISTEN 0      511             [::]:3000         [::]:*    users:(("node",pid=421,fd=21))
LISTEN 0      5            0.0.0.0:8000      0.0.0.0:*    users:(("python3",pid=430,fd=3))
LISTEN 0      244        127.0.0.1:5432      0.0.0.0:*    users:(("postgres",pid=500,fd=7))
LISTEN 0      511                *:4000            *:*    users:(("node",pid=510,fd=19))
LISTEN 0      128          0.0.0.0:22        0.0.0.0:*
LISTEN 0      511        127.0.0.1:47900     0.0.0.0:*    users:(("karmashala_host",pid=600,fd=9))
LISTEN 0      5          127.0.0.1:7777      0.0.0.0:*    users:(("sh",pid=700,fd=3))
@@end
''';

const LinuxSessionPane _pane = (
  paneId: 'p3',
  terminalSessionId: 'karmashala_s-wsl',
  title: 'analytics',
  command: null,
);

void main() {
  group('a look inside', () {
    late List<RunningProcess> read;

    RunningProcess byPid(int pid) => read.singleWhere((p) => p.pid == pid);

    setUp(() {
      read = attributeLinuxListing(
        parseLinuxListing(_listing),
        machine: 'wsl:Ubuntu',
        sessions: const {'s-wsl': _pane},
      );
    });

    test('a port an agent\'s child holds is that session\'s, once', () {
      final vite = byPid(421);
      expect(vite.role, RunningRole.child);
      expect(vite.agentSessionId, 's-wsl');
      expect(vite.paneId, 'p3');
      expect(vite.title, 'analytics');
      expect(vite.environmentId, 'wsl:Ubuntu');
      expect(vite.pidMachine, 'wsl:Ubuntu');
      expect(vite.name, 'node');
      expect(vite.commandLine, contains('vite --port 3000'));
      expect(vite.ports.map((p) => p.port), [3000], reason: 'v4 and v6');
      expect(vite.ports.single.host, isNull);
      expect(vite.stoppable, isTrue);
      expect(byPid(430).ports.single.port, 8000);
    });

    test('a process whose environment is unreadable takes its nearest '
        'ancestor\'s session', () {
      expect(byPid(422).agentSessionId, 's-wsl');
      expect(byPid(422).stoppable, isTrue);
    });

    test('the session\'s own root is listed but never stoppable', () {
      expect(byPid(410).agentSessionId, 's-wsl');
      expect(byPid(410).stoppable, isFalse);
    });

    test('what no session here started is listed under the machine only when '
        'it listens, and is never stoppable', () {
      final postgres = byPid(500);
      expect(postgres.role, RunningRole.listener);
      expect(postgres.paneId, isNull);
      expect(postgres.ports.single.port, 5432);
      expect(postgres.stoppable, isFalse);
      final elsewhere = byPid(510);
      expect(elsewhere.role, RunningRole.listener);
      expect(elsewhere.agentSessionId, isNull);
      expect(elsewhere.ports.single.address, '*');
      final host = byPid(600);
      expect(host.role, RunningRole.listener);
      expect(host.stoppable, isFalse);
      final unowned = byPid(0);
      expect(unowned.role, RunningRole.listener);
      expect(unowned.ports.single.port, 22);
      // init and the relays listen on nothing.
      expect(read.where((p) => p.pid == 1 || p.pid == 401), isEmpty);
    });

    test('the probe\'s own processes are nobody\'s', () {
      expect(read.where((p) => p.pid == 700 || p.pid == 701), isEmpty);
      expect(
        read.expand((p) => p.ports).where((port) => port.port == 7777),
        isEmpty,
      );
    });

    test('on a box, each port says the host it is reached at', () {
      final onBox = attributeLinuxListing(
        parseLinuxListing(_listing),
        machine: 'ssh:h1',
        sessions: const {'s-wsl': _pane},
        host: 'box.example',
      );
      final vite = onBox.singleWhere((p) => p.pid == 421);
      expect(vite.ports.single.host, 'box.example');
      expect(vite.pidMachine, 'ssh:h1');
    });

    test('a process is named by the program it runs, not its thread\'s '
        'name', () {
      final listing = parseLinuxListing(
        _listing.replaceFirst('  421 node\n', '  421 node-MainThread\n'),
      );
      final named = {for (final p in listing.processes) p.pid: p.name};
      expect(named[421], 'node');
      expect(named[420], 'npm');
      expect(named[600], 'karmashala_host');
    });

    test('a probe cut short is refused, not read as nothing running', () {
      expect(
        () => parseLinuxListing(_listing.replaceFirst('@@end', '')),
        throwsFormatException,
      );
    });
  });

  group('stopping inside', () {
    final listing = parseLinuxListing(_listing);
    const sessions = {'s-wsl': _pane};

    test('a child and what it started, children first', () {
      expect(linuxStopPlan(listing, 421, sessions), [422, 421]);
      expect(linuxStopScript([422, 421]), contains('kill -TERM 421'));
    });

    test('the session\'s root, Karmashala, a stranger, another session\'s '
        'process, the probe and a gone pid are refused', () {
      for (final pid in [410, 600, 500, 510, 700, 1, 4242]) {
        expect(
          () => linuxStopPlan(listing, pid, sessions),
          throwsA(
            isA<DataRefused>().having(
              (r) => r.code,
              'code',
              DataRefusalCode.denied,
            ),
          ),
          reason: 'pid $pid',
        );
      }
    });
  });

  test('the probe and a stop script parse under a real sh', () async {
    for (final script in [
      linuxRunningScript,
      linuxStopScript([422, 421]),
    ]) {
      final sh = await Process.start('sh', ['-n']);
      sh.stdin.write(script);
      await sh.stdin.close();
      final complaint = await sh.stderr
          .transform(systemEncoding.decoder)
          .join();
      expect(
        await sh.exitCode,
        0,
        reason: '$complaint\n--- script ---\n$script',
      );
    }
  }, testOn: '!windows');

  group('the server reads inside', () {
    late FakePtyLauncher launcher;
    late SessionRegistry registry;
    late List<String?> probed;
    late List<String> scripts;
    final ubuntu = ExecutionEnvironment(
      id: 'wsl:Ubuntu',
      createdAt: DateTime.utc(2026),
      name: 'Ubuntu',
      kind: EnvironmentKind.wsl,
      wslDistribution: 'Ubuntu',
    );
    final debian = ExecutionEnvironment(
      id: 'wsl:Debian',
      createdAt: DateTime.utc(2026),
      name: 'Debian',
      kind: EnvironmentKind.wsl,
      wslDistribution: 'Debian',
    );
    final arch = ExecutionEnvironment(
      id: 'wsl:Arch',
      createdAt: DateTime.utc(2026),
      name: 'Arch',
      kind: EnvironmentKind.wsl,
      wslDistribution: 'Arch',
    );

    setUp(() {
      launcher = FakePtyLauncher();
      registry = SessionRegistry(launcher: launcher, hostname: 'this-pc');
      probed = [];
      scripts = [];
    });

    tearDown(() async {
      for (final handle in launcher.handles) {
        handle.finish(0);
      }
    });

    ServerTerminals terminals() => ServerTerminals(
      registry: registry,
      environments: () => [ubuntu, debian, arch],
      tell: (_) {},
      windows: true,
      settle: Duration.zero,
      ports: ListeningPortProbe(
        windows: true,
        run: (executable, arguments) async =>
            ProcessResult(1, 0, 'P $pid 1 1 karmashala_host.exe\n', ''),
      ),
      wslShell: (distribution) => (script) async {
        probed.add(distribution);
        scripts.add(script);
        if (script.contains('kill -TERM')) return 'stopped\n';
        return distribution == 'Ubuntu'
            ? _listing
            : '@@self 9\n@@ps\n'
                  '    1     0 /init\n@@end\n';
      },
    );

    Future<void> openAll(ServerTerminals terminals) async {
      await terminals.handle(
        const TerminalOpen(
          paneId: 'p3',
          environmentId: 'wsl:Ubuntu',
          agentLaunch: AgentPaneLaunch(
            agentId: 'claudeCode',
            executable: 'claude',
            sessionId: 's-wsl',
            wslDistribution: 'Ubuntu',
          ),
          columns: 80,
          rows: 24,
        ),
      );
      await terminals.handle(
        const TerminalOpen(
          paneId: 'p4',
          environmentId: 'wsl:Ubuntu',
          columns: 80,
          rows: 24,
        ),
      );
      await terminals.handle(
        const TerminalOpen(
          paneId: 'p5',
          environmentId: 'wsl:Debian',
          columns: 80,
          rows: 24,
        ),
      );
    }

    test('one probe per distribution with a live pane, and none for a '
        'distribution with none', () async {
      final server = terminals();
      await openAll(server);
      await server.handle(const TerminalsRunning());
      expect(probed..sort(), ['Debian', 'Ubuntu']);
      expect(scripts.toSet().single, linuxRunningScript);
    });

    test('a WSL session\'s port 3000 is under that session, and it is not '
        'called unread', () async {
      final server = terminals();
      await openAll(server);
      final reading =
          await server.handle(const TerminalsRunning()) as RunningReading;
      final vite = reading.processes.singleWhere(
        (p) => p.pid == 421 && p.pidMachine == 'wsl:Ubuntu',
      );
      expect(vite.agentSessionId, 's-wsl');
      expect(vite.paneId, 'p3');
      expect(vite.ports.single.port, 3000);
      expect(
        reading.notes.where((n) => n.text.contains('runs in WSL')),
        isEmpty,
      );
    });

    test('a distribution that cannot be read says so on its machine', () async {
      final server = ServerTerminals(
        registry: registry,
        environments: () => [ubuntu],
        tell: (_) {},
        windows: true,
        settle: Duration.zero,
        ports: ListeningPortProbe(
          windows: true,
          run: (executable, arguments) async =>
              ProcessResult(1, 0, 'P $pid 1 1 karmashala_host.exe\n', ''),
        ),
        wslShell: (_) =>
            (_) async => throw const ProcessException('wsl', []),
      );
      await server.handle(
        const TerminalOpen(
          paneId: 'p4',
          environmentId: 'wsl:Ubuntu',
          columns: 80,
          rows: 24,
        ),
      );
      final reading =
          await server.handle(const TerminalsRunning()) as RunningReading;
      expect(reading.notes.single.environmentId, 'wsl:Ubuntu');
      expect(reading.notes.single.text, contains('WSL (Ubuntu)'));
    });

    test('Stop inside a distribution signals the tree there; the root and a '
        'stranger are refused', () async {
      final server = terminals();
      await openAll(server);
      await server.handle(
        const TerminalStopProcess(421, machine: 'wsl:Ubuntu'),
      );
      expect(scripts.last, linuxStopScript([422, 421]));
      expect(probed.last, 'Ubuntu');

      for (final pid in [410, 500, 600]) {
        await expectLater(
          server.handle(TerminalStopProcess(pid, machine: 'wsl:Ubuntu')),
          throwsA(isA<DataRefused>()),
          reason: 'pid $pid',
        );
      }
      // A machine with no session of this server's on it.
      await expectLater(
        server.handle(const TerminalStopProcess(421, machine: 'wsl:Arch')),
        throwsA(isA<DataRefused>()),
      );
      expect(scripts.where((s) => s.contains('kill')), hasLength(1));
    });
  });
}
