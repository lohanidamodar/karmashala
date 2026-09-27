import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:test/test.dart';

/// The panes adoption, attribution and worktree cleanup read (slice 5c): the
/// server's own terminals, read off its own screens — no client reports a
/// pane any more.
void main() {
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late ServerTerminals terminals;
  var changed = 0;

  setUp(() {
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, hostname: 'this-mac');
    terminals = ServerTerminals(
      registry: registry,
      environments: () => const <ExecutionEnvironment>[],
      tell: (_) {},
      hostEnvironment: const {'SHELL': '/bin/zsh'},
      installedShells: () => const ['/bin/zsh'],
      windows: false,
      settle: Duration.zero,
    );
    changed = 0;
    terminals.onPanesChanged = () => changed++;
  });

  tearDown(() {
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
  });

  test('a shell pane is live, where it was opened, running nothing', () {
    terminals.open(
      const TerminalOpen(
        paneId: 'p1',
        workingDirectory: '/src/app',
        columns: 80,
        rows: 24,
      ),
    );
    final pane = terminals.all.single;
    expect(pane.paneId, 'p1');
    expect(pane.live, isTrue);
    expect(pane.workingDirectory, '/src/app');
    expect(pane.hostsLaunchedSession, isFalse);
    expect(pane.lastCommandId, isNull);
    expect(pane.lastCommandRunning, isFalse);
    expect(changed, greaterThan(0));
  });

  test('its shell\'s OSC 7 and 133 are the pane\'s directory and command, '
      'running until the shell says it ended', () async {
    terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
    final pty = launcher.handles.single;
    pty.emit(utf8.encode('\x1b]7;file://this-mac/src/other\x07'));
    pty.emit(utf8.encode('\x1b]133;A\x07\$ \x1b]133;B\x07claude\r\n'));
    pty.emit(utf8.encode('\x1b]133;C\x07'));
    await pumpEventQueue();

    var pane = terminals.all.single;
    expect(pane.workingDirectory, '/src/other');
    expect(pane.lastCommandLine, 'claude');
    expect(pane.lastCommandRunning, isTrue);
    final first = pane.lastCommandId;
    expect(first, isNotNull);

    pty.emit(utf8.encode('\x1b]133;D\x07'));
    await pumpEventQueue();
    pane = terminals.all.single;
    expect(pane.lastCommandRunning, isFalse, reason: 'D with no code ends it');

    // The same command run again is another block.
    pty.emit(utf8.encode('\x1b]133;A\x07\$ \x1b]133;B\x07claude\r\n'));
    pty.emit(utf8.encode('\x1b]133;C\x07'));
    await pumpEventQueue();
    pane = terminals.all.single;
    expect(pane.lastCommandId, isNot(first));
    expect(pane.lastCommandRunning, isTrue);
  });

  test('an agent pane is a launched session, never one to adopt', () {
    terminals.open(
      const TerminalOpen(
        paneId: 'p2',
        agentLaunch: AgentPaneLaunch(
          agentId: 'claudeCode',
          executable: '/usr/local/bin/claude',
          arguments: [],
          workingDirectory: '/src/app',
          sessionId: 'row-1',
          title: 'Work',
        ),
        columns: 80,
        rows: 24,
      ),
    );
    final pane = terminals.all.single;
    expect(pane.hostsLaunchedSession, isTrue);
    expect(pane.workingDirectory, '/src/app');
  });

  test('a tail is read off the server\'s own screen, when asked', () async {
    terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
    launcher.handles.single.emit(utf8.encode('one\r\ntwo\r\n'));
    await pumpEventQueue();
    final tail = terminals.tailOf('p1', 5)!;
    expect(tail.join('\n'), contains('two'));
    expect(terminals.tailOf('nobody', 5), isNull);
  });

  test('an ended pane is not live; a closed one is gone', () async {
    terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
    launcher.handles.single.finish(0);
    await registry.find('karmashala_local_p1')!.ended;
    await pumpEventQueue();
    expect(terminals.all.single.live, isFalse);

    await terminals.close('karmashala_local_p1');
    expect(terminals.all, isEmpty);
  });
}
