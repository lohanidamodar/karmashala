import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/wsl_distributions.dart';
import 'package:agent_cli/src/environments/environment_discovery_service.dart';
import 'package:agent_cli/src/environments/local_environment.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';

void main() {
  group('parseWslDistributions', () {
    test('parses clean output', () {
      expect(parseWslDistributions('Ubuntu\nDebian\n'), ['Ubuntu', 'Debian']);
    });

    test('strips UTF-16 NUL interleaving, BOM and blank lines', () {
      // Build the kind of bytes `wsl --list --quiet` produces once decoded:
      // a leading BOM (0xFEFF), each character followed by a NUL (0x00), CRLFs
      // and a blank line.
      const bom = 0xFEFF;
      const nul = 0x00;
      List<int> withNuls(String s) => [
        for (final c in s.codeUnits) ...[c, nul],
      ];
      final raw = String.fromCharCodes([
        bom,
        ...withNuls('Ubuntu'),
        0x0D, 0x0A, 0x0D, 0x0A, // \r\n\r\n (blank line)
        ...withNuls('Debian'),
        0x0D, 0x0A,
      ]);
      expect(parseWslDistributions(raw), ['Ubuntu', 'Debian']);
    });

    test('empty output yields no distributions', () {
      expect(parseWslDistributions(''), isEmpty);
    });

    test('strips a default-distro marker and the non-quiet header', () {
      const raw =
          'Windows Subsystem for Linux Distributions:\r\n'
          '* Ubuntu\r\n'
          '  Debian\r\n';
      expect(parseWslDistributions(raw), ['Ubuntu', 'Debian']);
    });

    test('keeps distribution names containing spaces', () {
      expect(parseWslDistributions('Docker Desktop\n'), ['Docker Desktop']);
    });
  });

  group('one parse, shared by everything that asks', () {
    /// The drainer skips a distribution that is not in the running set, so it
    /// compares a name it parsed against a name environment discovery stored.
    /// If those two disagree the skip is permanent and silent — no error, no
    /// log, just a distribution whose agents never report status again.
    ///
    /// This is not hypothetical: the running-set reader briefly carried a
    /// second parser that stripped every space, which turns `Docker Desktop`
    /// into `DockerDesktop` and makes the comparison below fail while both
    /// halves look correct in isolation.
    test('a name with a space survives the running-set reader', () {
      const running = 'Docker Desktop\r\nUbuntu\r\n';
      const listed = 'Docker Desktop\r\nUbuntu\r\n';

      final stored = parseWslDistributions(listed);
      final live = parseWslDistributions(running).toSet();

      expect(stored, ['Docker Desktop', 'Ubuntu']);
      for (final name in stored) {
        expect(
          live.contains(name),
          isTrue,
          reason:
              'the drainer would skip "$name" for the life of the process, '
              'without saying so',
        );
      }
    });
  });

  group('EnvironmentDiscoveryService', () {
    test('always includes the host environment', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
        hostIsWindows: true,
      ).discover();
      // The host row describes the machine the suite is running on. Only WSL
      // enumeration is gated by [hostIsWindows].
      expect(envs.single.kind, localHostEnvironmentKind);
      expect(envs.single.id, localHostEnvironmentId);
    });

    test('a POSIX host is itself, and is never asked about WSL', () async {
      var asked = false;
      final runner = FakeCommandRunner(
        responder: (_) {
          asked = true;
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
        hostIsWindows: false,
      ).discover();

      expect(envs.single.id, localHostEnvironmentId);
      // Not merely "found nothing": nothing was spawned. A Mac used to run
      // wsl.exe on every launch and log its absence as though it were news.
      expect(asked, isFalse, reason: 'wsl.exe must not be run off Windows');
    });

    test('the wsl.exe probe is bounded, so a wedged one cannot hang discovery', () async {
      final runner = FakeCommandRunner();
      await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
        hostIsWindows: true,
      ).discover();

      expect(runner.requests.single.timeout, kProbeTimeout);
    });

    test('adds a wsl: environment per discovered distribution', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          expect(req.executable, 'wsl.exe');
          expect(req.arguments, ['--list', '--quiet']);
          return const CommandResult(
            exitCode: 0,
            stdout: 'Ubuntu\nDebian\n',
            stderr: '',
          );
        },
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
        hostIsWindows: true,
      ).discover();
      expect(envs.map((e) => e.id), [
        localHostEnvironmentId,
        'wsl:Ubuntu',
        'wsl:Debian',
      ]);
      expect(envs[1].wslDistribution, 'Ubuntu');
    });

    test('degrades to Windows-only when wsl.exe is unavailable', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('wsl.exe not found'),
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
        hostIsWindows: true,
      ).discover();
      expect(envs.map((e) => e.id), [localHostEnvironmentId]);
    });

    test('degrades to Windows-only on a non-zero exit', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
        hostIsWindows: true,
      ).discover();
      expect(envs.map((e) => e.id), [localHostEnvironmentId]);
    });
  });
}
