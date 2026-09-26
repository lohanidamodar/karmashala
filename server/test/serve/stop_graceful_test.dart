@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../server/server_test_support.dart';

/// `stop` shuts a host down the graceful way. Found live: the standalone
/// server exited 158 (SIGUSR1) because the liveness probe that followed the
/// SIGTERM *sent* SIGUSR1, whose default action ends the process — mid
/// shutdown, before its records and handshake files were put away.
void main() {
  group('processIsAlive', () {
    test('asks without signalling: a process with no handler for anything '
        'survives any number of probes', () async {
      final sleeper = await Process.start('sleep', ['30']);
      addTearDown(() => sleeper.kill(ProcessSignal.sigkill));
      for (var i = 0; i < 20; i++) {
        expect(processIsAlive(sleeper.pid), isTrue);
      }
      final ended = await sleeper.exitCode
          .then<int?>((code) => code)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => null);
      expect(ended, isNull, reason: 'the probe ended the process ($ended)');
      expect(processIsAlive(sleeper.pid), isTrue);
    });

    test('a process that is gone is not alive', () async {
      final sleeper = await Process.start('sleep', ['30']);
      sleeper.kill(ProcessSignal.sigkill);
      await sleeper.exitCode;
      expect(processIsAlive(sleeper.pid), isFalse);
      expect(processIsAlive(0), isFalse);
      expect(processIsAlive(-1), isFalse);
    });

    test('a process that is there but not ours is alive', () {
      // pid 1 is always there, and never this user's to signal.
      expect(processIsAlive(1), isTrue);
    });
  });

  test('stop ends a real host through its own shutdown: exit 0, and what '
      'it holds put away', () async {
    final root = Directory.systemTemp.createTempSync('kh-stop');
    addTearDown(() => root.deleteSync(recursive: true));
    final hostDir = p.join(root.path, 'host');
    final host = await Process.start(
      Platform.resolvedExecutable,
      [
        'bin/karmashala_host.dart',
        'serve',
        '--data-dir=${p.join(root.path, 'data')}',
        '--no-companion',
        '--mcp-port=0',
      ],
      environment: {
        'HOME': p.join(root.path, 'home'),
        kHostDirectoryEnvironmentVariable: hostDir,
      },
    );
    addTearDown(() => host.kill(ProcessSignal.sigkill));
    final said = StringBuffer();
    final greeted = Completer<void>();
    host.stdout.transform(utf8.decoder).listen((text) {
      said.write(text);
      if (said.toString().contains('restored ') && !greeted.isCompleted) {
        greeted.complete();
      }
    });
    host.stderr.transform(utf8.decoder).listen(said.write);
    await Future.any([
      greeted.future,
      host.exitCode.then((code) => fail('serve exited $code:\n$said')),
    ]).timeout(const Duration(minutes: 2));

    final paths = HostPaths(Directory(hostDir));
    expect(File(paths.holderDataDirectoryPath).existsSync(), isTrue);
    final out = CapturingSink();
    final err = CapturingSink();
    expect(
      await runStop(const [], out: out, err: err, paths: paths),
      0,
      reason: '${err.text}',
    );
    expect(out.text.toString(), contains('stopped pid ${host.pid}'));
    expect(out.text.toString(), isNot(contains('ignored the first signal')));
    expect(
      await host.exitCode.timeout(const Duration(seconds: 10)),
      0,
      reason: '$said',
    );
    // Released on the way out, which only the graceful path does.
    expect(File(paths.holderDataDirectoryPath).existsSync(), isFalse);
  });
}
