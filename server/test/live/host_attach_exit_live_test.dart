@Tags(['live'])
// The first case pays for the host build (`local_host_harness.dart`), which
// outlasts package:test's default 30 s on a busy machine.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'local_host_harness.dart';

/// **An `attach` never outlives both of its ends.** On the droplet one sat for
/// five days, reparented to init, after the `serve` it proxied for was replaced
/// and the SSH channel that started it was gone.
void main() {
  late Directory home;
  late LocalHost host;

  setUp(() async {
    home = temporaryHome('karmashala-host-attach');
    host = await LocalHost.start(home);
  });

  tearDown(() async => host.kill());

  Future<Process> attach() async {
    final process = await Process.start(
      await builtHost,
      ['attach'],
      environment: {'USERPROFILE': home.path, 'HOME': home.path},
    );
    process.stdout.listen((_) {});
    process.stderr.listen((_) {});
    // Long enough for the host's socket to have taken it.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return process;
  }

  Future<int> exitWithin(Process process, Duration bound) =>
      process.exitCode.timeout(
        bound,
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

  test('it ends when the host it proxies for dies', () async {
    final process = await attach();
    await host.kill();
    expect(
      await exitWithin(process, const Duration(seconds: 10)),
      isNot(-1),
      reason: 'attach was still running 10 s after its host died',
    );
  });

  test('it ends when its own end goes away', () async {
    final process = await attach();
    await process.stdin.close();
    expect(
      await exitWithin(process, const Duration(seconds: 10)),
      isNot(-1),
      reason: 'attach was still running 10 s after its stdin closed',
    );
  });
}
