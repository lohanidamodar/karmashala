@Tags(['live-wsl'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/domain/host_session.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/pty_platform.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_launch/karmashala_launch.dart';
import 'package:test/test.dart';

import 'wsl_harness.dart';

/// A WSL pane as the server runs it since slice 5a — the successor of the
/// app's `live_wsl_*` suites, which drove `flutter_pty`: the server's own
/// ConPTY, the launch it builds on Windows (`wsl.exe -d … --cd …` direct, no
/// `cmd.exe /c`), and its copy of the screen. Each question is about a
/// boundary no unit test can see: a byte written into a **Windows**
/// pseudoconsole that a **Linux** process has to notice, three relays away.
///
/// Skips itself off Windows, or without the `archlinux` distribution the
/// other live-wsl tests use.
void main() {
  final unavailable = WslHarness.unavailableReason();
  if (unavailable != null) {
    test('live WSL terminals are skipped', () {}, skip: unavailable);
    return;
  }
  const distro = 'archlinux';
  final wsl = ExecutionEnvironment(
    id: 'wsl:$distro',
    name: distro,
    kind: EnvironmentKind.wsl,
    wslDistribution: distro,
    createdAt: DateTime.utc(2026),
  );

  late SessionRegistry registry;
  late ServerTerminals terminals;

  setUp(() {
    registry = SessionRegistry(launcher: resolvePtyPlatform().launcher);
    terminals = ServerTerminals(
      registry: registry,
      environments: () => [wsl],
      tell: (_) {},
      windows: true,
      settle: Duration.zero,
    );
  });

  tearDown(() => registry.shutdown());

  String screenOf(HostSession session) =>
      session.tailText(60).join('\n');

  Future<void> until(
    bool Function() condition, {
    Duration within = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(within);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void type(HostSession session, String text) =>
      session.typeAsHost(Uint8List.fromList(utf8.encode(text)));

  test('an integrated WSL shell reports its command, folder and exit '
      'through the server\'s screen', () async {
    final opened = terminals.open(
      TerminalOpen(
        paneId: 'live-osc',
        environmentId: wsl.id,
        workingDirectory: '/tmp',
        columns: 120,
        rows: 30,
        shellIntegration: true,
      ),
    );
    expect(opened.shellIntegration, isTrue);
    final session = registry.find(opened.sessionId)!;
    await until(() => session.facts?.workingDirectory == '/tmp');
    type(session, 'false\r');
    await until(() => session.facts?.lastCommandExitCode == 1);
    expect(session.facts?.lastCommand, 'false');
    printOnFailure(screenOf(session));
  });

  test('Ctrl+C reaches the process inside a WSL pane', () async {
    final opened = terminals.open(
      TerminalOpen(
        paneId: 'live-ctrl-c',
        environmentId: wsl.id,
        columns: 120,
        rows: 30,
      ),
    );
    final session = registry.find(opened.sessionId)!;
    await Future<void>.delayed(const Duration(seconds: 2));
    type(session, 'sleep 30; echo AFTER-SLEEP\r');
    await Future<void>.delayed(const Duration(seconds: 1));
    type(session, '\x03');
    type(session, 'echo INTERRUPTED\r');
    await until(() => screenOf(session).contains('\nINTERRUPTED'));
    expect(screenOf(session), isNot(contains('\nAFTER-SLEEP')));
    expect(session.lifecycle.hasEnded, isFalse, reason: 'the shell lives');
  });

  test('a WSL agent\'s prompt arrives exactly as written', () async {
    const prompt = r'he said "hi" & ran `id` $(whoami) 50%USERNAME% done';
    final opened = terminals.open(
      const TerminalOpen(
        paneId: 'live-prompt',
        agentLaunch: AgentPaneLaunch(
          agentId: 'probe',
          executable: 'printf',
          arguments: ['[%s]\n', prompt],
          wslDistribution: distro,
          sessionId: 'live-prompt-session',
        ),
        columns: 160,
        rows: 20,
      ),
    );
    final session = registry.find(opened.sessionId)!;
    await session.ended.timeout(const Duration(seconds: 20));
    expect(screenOf(session), contains('[$prompt]'));
    expect(session.lifecycle.exitCode, 0);
  });

  test('closing a WSL pane reaps the process tree inside the distro', () async {
    final marker = 'karmashala-reap-${DateTime.now().microsecondsSinceEpoch}';
    final opened = terminals.open(
      TerminalOpen(
        paneId: 'live-reap',
        environmentId: wsl.id,
        columns: 120,
        rows: 30,
      ),
    );
    final session = registry.find(opened.sessionId)!;
    await Future<void>.delayed(const Duration(seconds: 2));
    type(session, 'exec -a $marker sleep 600\r');
    bool running() =>
        Process.runSync('wsl.exe', [
          '-d',
          distro,
          '--',
          'pgrep',
          '-f',
          marker,
        ]).exitCode ==
        0;
    await until(running);
    await terminals.close(opened.sessionId);
    await until(() => !running(), within: const Duration(seconds: 15));
  });
}
