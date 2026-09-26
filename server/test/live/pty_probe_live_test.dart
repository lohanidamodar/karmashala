@Tags(['live-wsl'])
library;

import 'package:test/test.dart';

import 'wsl_harness.dart';

void main() {
  final unavailable = WslHarness.unavailableReason();

  test(
    'the cross-compiled host runs a real pty inside WSL',
    () {
      final harness = WslHarness.prepare();
      final result = harness.runSync(
        '${harness.installScript('/tmp/karmashala_host_probe')}\n'
        '${WslHarness.executableIn('/tmp/karmashala_host_probe')} probe-pty',
      );
      final output = '${result.stdout}${result.stderr}';
      printOnFailure(output);

      expect(result.exitCode, 0, reason: output);
      expect(output, contains('PROBE OK'));
      // The library that answered is a measurement of the target, not a
      // constant: glibc < 2.34 keeps openpty in libutil.
      expect(output, matches(RegExp(r'pty-lib\s+lib(c\.so\.6|util\.so\.1)')));
      expect(output, contains('ok   echo round-trip'));
      expect(output, contains('ok   resize -> reported size'));
      expect(output, contains('ok   exit code  got 7'));
    },
    skip: unavailable,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
