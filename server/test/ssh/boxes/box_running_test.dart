import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/terminals/linux_running.dart';
import 'package:karmashala_host/src/terminals/listening_ports.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:test/test.dart';

import '../support/box_world.dart';

/// The Running tab on an SSH box: read over a connection that is already
/// open, never one dialled to list.
void main() {
  late BoxWorld world;
  late List<String> scripts;

  setUp(() {
    world = BoxWorld();
    scripts = [];
  });
  tearDown(() => world.close());

  const listing = '''
@@self 90
@@ps
    1     0 /sbin/init
   40     1 /home/dev/.karmashala/host/bin/karmashala_host serve
   50    40 /bin/bash -l
   51    50 node /usr/bin/claude
   52    51 node server.js
   90     1 sh -c
@@comm
    1 systemd
   40 karmashala_host
   50 bash
   51 node
   52 node
   90 sh
@@env
/proc/50/environ:KARMASHALA_SESSION_ID=s-box
/proc/51/environ:KARMASHALA_SESSION_ID=s-box
/proc/52/environ:KARMASHALA_SESSION_ID=s-box
@@ss
LISTEN 0 511 0.0.0.0:8080 0.0.0.0:* users:(("node",pid=52,fd=20))
@@end
''';

  ServerTerminals terminals({BoxShell? Function(String hostId)? boxShell}) =>
      ServerTerminals(
        registry: SessionRegistry(launcher: FakePtyLauncher()),
        environments: () => world.data.environments,
        tell: (_) {},
        windows: false,
        remote: world.ssh.remote,
        settle: Duration.zero,
        boxShell: boxShell,
        ports: ListeningPortProbe(
          windows: false,
          run: (executable, arguments) async => ProcessResult(
            1,
            0,
            executable == 'ps' ? '$pid 1 dart\n' : '',
            '',
          ),
        ),
      );

  Future<void> openAgent(ServerTerminals server) => server.openAnywhere(
    const TerminalOpen(
      paneId: 'p1',
      environmentId: 'ssh:h1',
      agentLaunch: AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        sessionId: 's-box',
        sshHostId: 'h1',
      ),
      columns: 80,
      rows: 24,
    ),
  );

  test('the domain hands out no shell to a box it is not connected to, and '
      'does not dial one', () {
    expect(world.ssh.openShell(BoxWorld.hostId), isNull);
    expect(world.ssh.openShell('no-such-host'), isNull);
  });

  test('with no connection open, the box\'s panes are kept with the note '
      'saying so, and Stop there is refused', () async {
    final server = terminals();
    await openAgent(server);
    final reading =
        await server.handle(const TerminalsRunning()) as RunningReading;
    final pane = reading.processes.singleWhere(
      (p) => p.environmentId == 'ssh:h1',
    );
    expect(pane.pid, 0);
    expect(pane.agentSessionId, 's-box');
    expect(reading.notes.single.environmentId, 'ssh:h1');
    expect(reading.notes.single.text, contains('no connection open'));
    await expectLater(
      server.handle(const TerminalStopProcess(52, machine: 'ssh:h1')),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.unavailable,
        ),
      ),
    );
  });

  test('over an open connection, the session\'s processes are read and each '
      'port names the box; Stop signals it there', () async {
    final server = terminals(
      boxShell: (hostId) => (
        address: '203.0.113.9',
        run: (script) async {
          scripts.add(script);
          return script.contains('kill -TERM') ? 'stopped\n' : listing;
        },
      ),
    );
    await openAgent(server);
    final reading =
        await server.handle(const TerminalsRunning()) as RunningReading;
    final node = reading.processes.singleWhere((p) => p.pid == 52);
    expect(node.agentSessionId, 's-box');
    expect(node.pidMachine, 'ssh:h1');
    expect(node.ports.single.host, '203.0.113.9');
    expect(node.stoppable, isTrue);
    expect(
      reading.processes.singleWhere((p) => p.pid == 50).stoppable,
      isFalse,
    );
    expect(reading.notes, isEmpty);

    await server.handle(const TerminalStopProcess(52, machine: 'ssh:h1'));
    expect(scripts.last, linuxStopScript([52]));
    await expectLater(
      server.handle(const TerminalStopProcess(40, machine: 'ssh:h1')),
      throwsA(isA<DataRefused>()),
      reason: 'the Karmashala server there',
    );
  });
}
