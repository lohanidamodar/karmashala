@Tags(['live-wsl'])
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/terminals/linux_running.dart';
import 'package:test/test.dart';

import 'wsl_harness.dart';

/// The Running tab's look inside a real distribution: the script under the
/// distribution's own `sh`, `/proc/<pid>/environ` as WSL really exposes it,
/// `ss` as installed. A throwaway `python3 -m http.server`, started under a
/// made-up session id, is found under that id, stopped through the same
/// script Stop sends, and anything left of it is killed after.
///
/// Skips itself off Windows, or without the `archlinux` distribution the
/// other live-wsl tests use, or without python3 in it.
void main() {
  final unavailable = WslHarness.unavailableReason();
  if (unavailable != null) {
    test('looking inside WSL is skipped', () {}, skip: unavailable);
    return;
  }
  const distro = 'archlinux';
  final sessionId = 'r33-live-${DateTime.now().microsecondsSinceEpoch}';
  final port = 21000 + (pid % 4000);
  final shell = wslShell(distro);
  final sessions = <String, LinuxSessionPane>{
    sessionId: (
      paneId: 'live-pane',
      terminalSessionId: 'karmashala_$sessionId',
      title: 'live',
      command: null,
    ),
  };
  Process? relay;

  /// Ends everything whose environment names [sessionId]: only what this
  /// test started.
  Future<void> killOurs() async {
    final listing = parseLinuxListing(await shell(linuxRunningScript));
    final ours = [
      for (final process in listing.processes)
        if (process.sessionId == sessionId && process.pid != listing.probe)
          process.pid,
    ];
    if (ours.isNotEmpty) await shell('kill -KILL ${ours.join(' ')}');
  }

  tearDownAll(() async {
    await killOurs();
    relay?.kill();
  });

  test('a port a session\'s child holds is found under that session, and '
      'Stop ends it', () async {
    final python = await shell('command -v python3 || echo none');
    if (python.trim() == 'none' || python.trim().isEmpty) {
      markTestSkipped('python3 is not installed in $distro');
      return;
    }
    // The session's root is the sh; python is its child, as a dev server
    // under an agent is. `env`, so the id is in the sh's own environ.
    relay = await Process.start('wsl.exe', [
      '-d',
      distro,
      '-e',
      'env',
      'KARMASHALA_SESSION_ID=$sessionId',
      'sh',
      '-c',
      'python3 -m http.server $port --bind 127.0.0.1 >/dev/null 2>&1 & wait',
    ]);
    unawaited(relay!.stdout.drain<void>());
    unawaited(relay!.stderr.drain<void>());

    RunningProcess? server;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (server == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final read = attributeLinuxListing(
        parseLinuxListing(await shell(linuxRunningScript)),
        machine: 'wsl:$distro',
        sessions: sessions,
      );
      server = read
          .where((p) => p.ports.any((each) => each.port == port))
          .firstOrNull;
    }
    expect(server, isNotNull, reason: 'port $port was never seen listening');
    expect(server!.agentSessionId, sessionId);
    expect(server.role, RunningRole.child);
    expect(server.commandLine, contains('http.server'));
    expect(server.stoppable, isTrue);

    final listing = parseLinuxListing(await shell(linuxRunningScript));
    final root = listing.processes.firstWhere((p) => p.pid == server!.parent);
    expect(
      () => linuxStopPlan(listing, root.pid, sessions),
      throwsA(isA<DataRefused>()),
      reason: 'the session\'s own root',
    );
    final plan = linuxStopPlan(listing, server.pid, sessions);
    expect(await shell(linuxStopScript(plan)), contains('stopped'));

    var gone = false;
    final until = DateTime.now().add(const Duration(seconds: 10));
    while (!gone && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final after = parseLinuxListing(await shell(linuxRunningScript));
      gone = !after.sockets.any((socket) => socket.port == port);
    }
    expect(gone, isTrue, reason: 'port $port still listens after Stop');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
