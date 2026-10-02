@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/pty_platform.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:test/test.dart';

/// A shell the server starts for a pane (slice 5a), on this machine's real
/// POSIX pty: the launch built here, the vault laid in, and the server's own
/// screen reading what the shell says. `/bin/sh`, so no rc file of the
/// person's runs; nothing is written outside a temp folder.
void main() {
  if (Platform.isWindows) {
    test('POSIX terminals live test', () {}, skip: 'POSIX only');
    return;
  }
  late SessionRegistry registry;
  late ServerTerminals terminals;
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('kst');
    registry = SessionRegistry(launcher: resolvePtyPlatform().launcher);
    terminals = ServerTerminals(
      registry: registry,
      environments: () => const [],
      tell: (_) {},
      overlay: () => const {'KARMASHALA_TEST_VAULT': 'from-the-vault'},
      hostEnvironment: const {'SHELL': '/bin/sh'},
      installedShells: () => const ['/bin/sh'],
      windows: false,
      settle: Duration.zero,
    );
  });
  tearDown(() async {
    await registry.shutdown();
    folder.deleteSync(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('a pane\'s shell runs in the server, in its folder, with the vault, '
      'and its screen is read there', () async {
    final opened = terminals.open(
      TerminalOpen(
        paneId: 'live-p1',
        profileId: 'posix:/bin/sh',
        workingDirectory: folder.path,
        columns: 100,
        rows: 30,
      ),
    );
    final session = registry.find(opened.sessionId)!;
    String screen() => session.tailText(30).join('\n');
    session.typeAsHost(
      Uint8List.fromList(
        utf8.encode(
          'echo "[\$KARMASHALA_TEST_VAULT]" "[\$(pwd -P)]"; '
          r"printf '\033]0;titled\007\033]7;file://localhost/tmp\007'; "
          'exit 3\r',
        ),
      ),
    );
    await session.ended.timeout(const Duration(seconds: 10));
    await until(() => terminals.records.single.endedAt != null);

    expect(screen(), contains('[from-the-vault]'));
    expect(screen(), contains('[${folder.resolveSymbolicLinksSync()}]'));
    final record = terminals.records.single;
    expect(record.title, 'titled');
    expect(record.workingDirectory, '/tmp');
    expect(record.isLive, isFalse);
    // The code, or the honest absence of one: in a process where `dart:io`
    // also runs children (this test runner; `serve` running git), its SIGCHLD
    // handler can reap the shell before the pty reader's `waitpid` does
    // (ECHILD) — never a guessed zero.
    if (record.exitCode == null) {
      expect(record.endReason, contains('could not be reaped'));
    } else {
      expect(record.exitCode, 3);
    }
  });
}
