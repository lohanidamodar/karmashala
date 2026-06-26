import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/environments/data/environment_discovery_service.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

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
  });

  group('EnvironmentDiscoveryService', () {
    test('always includes the Windows host environment', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
      ).discover();
      expect(envs.single.kind, EnvironmentKind.windowsNative);
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
      ).discover();
      expect(envs.map((e) => e.id), ['windows', 'wsl:Ubuntu', 'wsl:Debian']);
      expect(envs[1].wslDistribution, 'Ubuntu');
    });

    test('degrades to Windows-only when wsl.exe is unavailable', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('wsl.exe not found'),
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
      ).discover();
      expect(envs.map((e) => e.id), ['windows']);
    });

    test('degrades to Windows-only on a non-zero exit', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );
      final envs = await EnvironmentDiscoveryService(
        host: runner,
        clock: FixedClock(testTime),
      ).discover();
      expect(envs.map((e) => e.id), ['windows']);
    });
  });
}
