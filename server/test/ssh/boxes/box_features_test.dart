import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/flutter/hosted_runs.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:test/test.dart';

import '../support/box_world.dart';

/// What the rest of the server starts on an SSH box through the ssh domain's
/// `RemoteSessions` (slice 5d), against a box in this process: a terminal (a
/// shell or an agent) and a hosted run — each a session of the box's host,
/// under the id a client computes for it, read here like a local one.
void main() {
  late BoxWorld world;
  late ServerTerminals terminals;
  late List<DataChange> told;

  setUp(() {
    world = BoxWorld();
    told = [];
    terminals = ServerTerminals(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      environments: () => world.data.environments,
      tell: told.addAll,
      windows: false,
      remote: world.ssh.remote,
      settle: Duration.zero,
    );
  });
  tearDown(() => world.close());

  test('an SSH terminal opens on the box, named for the client '
      '`ssh:<hostId>/<id>`', () async {
    final opened = await terminals.openAnywhere(
      const TerminalOpen(
        paneId: 'p1',
        environmentId: 'ssh:h1',
        workingDirectory: '/home/dev/api',
        columns: 90,
        rows: 30,
      ),
    );
    expect(opened.sessionId, 'ssh:h1/karmashala_local_p1');
    expect(opened.adopted, isFalse);
    final pty = world.box.ptys.single;
    expect(pty.request.argv, ['/bin/bash', '-l']);
    expect(pty.request.workingDirectory, '/home/dev/api');
    final record = terminals.records.single;
    expect(record.sessionId, 'ssh:h1/karmashala_local_p1');
    expect(record.environmentId, 'ssh:h1');

    // Its title is read off the server's copy of the box's screen.
    pty.emit(utf8.encode('\x1b]2;deploying\x07'));
    await until(() => terminals.records.single.title == 'deploying');
    expect(terminals.records.single.title, 'deploying');

    // Asked again, it is the same terminal.
    final again = await terminals.openAnywhere(
      const TerminalOpen(
        paneId: 'p1',
        environmentId: 'ssh:h1',
        columns: 90,
        rows: 30,
      ),
    );
    expect(again.adopted, isTrue);
    expect(world.box.ptys, hasLength(1));

    // Closed for good: at the box.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 20),
        () => pty.finish(143),
      ),
    );
    await terminals.close('ssh:h1/karmashala_local_p1');
    expect(pty.signals, contains(15));
    expect(terminals.records, isEmpty);
  });

  test('an agent on the box runs its own command under its session\'s id, '
      'told its session id', () async {
    final opened = await terminals.openAnywhere(
      const TerminalOpen(
        paneId: 'session-s1',
        agentLaunch: AgentPaneLaunch(
          agentId: 'claude-code',
          executable: '/usr/bin/claude',
          arguments: ['--resume', 'conv-1'],
          workingDirectory: '/home/dev/api',
          sshHostId: 'h1',
          sessionId: 's1',
          title: 'Fix the cart',
        ),
        columns: 120,
        rows: 40,
      ),
    );
    expect(opened.sessionId, 'ssh:h1/karmashala_s1');
    final pty = world.box.ptys.single;
    expect(pty.request.argv, ['/usr/bin/claude', '--resume', 'conv-1']);
    expect(pty.request.environment[kSessionIdEnvironmentVariable], 's1');
    expect(pty.request.workingDirectory, '/home/dev/api');
    expect(terminals.all.single.hostsLaunchedSession, isTrue);
  });

  test('a hosted run on the box: its tail and its exit, the box\'s', () async {
    final runs = HostedRuns(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      tell: told.addAll,
      newId: () => 'r1',
      windows: false,
      remote: world.ssh.remote,
    );
    expect(runs.refusalFor(world.environment), isNull);
    final ended = <HostedRun>[];
    final run = await runs.start(
      argv: const ['flutter', 'build', 'apk'],
      directory: const EnvironmentPath(
        environmentId: 'ssh:h1',
        path: '/home/dev/app',
      ),
      environment: world.environment,
      title: 'build',
      family: HostedRunFamily.build,
      onEnded: ended.add,
    );
    final pty = world.box.ptys.single;
    expect(pty.request.argv, ['flutter', 'build', 'apk']);
    expect(pty.request.workingDirectory, '/home/dev/app');
    // The pane a client opens on it is the one a local run's would be.
    expect(
      world.ssh.remote.byId(hostedRunSessionId(hostedRunPaneId(run.runId))),
      isNotNull,
    );
    pty.emit(utf8.encode('Built build/app.apk\r\n'));
    await until(() => runs.tailOf('r1').join().contains('Built'));
    expect(runs.tailOf('r1'), contains('Built build/app.apk'));
    expect(runs.livenessOf('r1'), HostedRunLiveness.running);
    pty.finish(0);
    await until(() => ended.isNotEmpty);
    expect(ended.single.exitCode, 0);
    expect(runs.livenessOf('r1'), HostedRunLiveness.finished);
  });
}
