import 'dart:convert';
import 'dart:io';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end proof that the in-app terminal can actually start Windows shells.
///
/// Reproduces exactly what `PtyTerminalInstance` does — spawns a real ConPTY with
/// the full host environment — and asserts the shell runs a command and emits its
/// output. The env is the fix: without SystemRoot/WINDIR/… powershell.exe and
/// wsl.exe fail to start.
///
/// Every case needs a Windows host, and the WSL case needs a distribution as
/// well. Both prerequisites are checked, and an absent one is a **skip with a
/// reason** — never a green pass, which is what the WSL case used to do.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Whether `wsl.exe -l -q` lists at least one distribution. Wrapped because
  /// on a host without WSL the executable itself is missing and `Process.run`
  /// throws rather than returning a non-zero exit code.
  Future<bool> hasWslDistribution() async {
    if (!Platform.isWindows) return false;
    try {
      // `stdoutEncoding: null` because wsl.exe writes UTF-16LE; decoding it as
      // the system encoding turns every name into interleaved NULs.
      final result = await Process.run('wsl.exe', [
        '-l',
        '-q',
      ], stdoutEncoding: null);
      if (result.exitCode != 0) return false;
      final listed = String.fromCharCodes(
        (result.stdout as List<int>).where((b) => b != 0),
      );
      return listed.trim().isNotEmpty;
    } on ProcessException {
      return false;
    }
  }

  Future<String> runInPty(String exe, List<String> args) async {
    final pty = Pty.start(
      exe,
      arguments: args,
      environment: Map<String, String>.of(Platform.environment),
    );
    final out = StringBuffer();
    final sub = pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(out.write);
    // Give the shell time to start and print.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!out.toString().contains('PTY_OK') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await sub.cancel();
    pty.kill();
    return out.toString();
  }

  /// `testWidgets` only takes a bool for `skip`, so a reason is recorded the way
  /// the reporter shows it. Returns true when the case cannot run here.
  bool skipUnlessWindows(String what) {
    if (Platform.isWindows) return false;
    markTestSkipped('$what needs a Windows host with ConPTY.');
    return true;
  }

  testWidgets('PowerShell starts in a PTY and runs a command', (tester) async {
    if (skipUnlessWindows('powershell.exe')) return;
    final output = await runInPty('powershell.exe', [
      '-NoLogo',
      '-Command',
      'Write-Output PTY_OK',
    ]);
    expect(output, contains('PTY_OK'), reason: 'powershell.exe did not run');
  }, timeout: const Timeout(Duration(seconds: 40)));

  testWidgets('cmd.exe starts in a PTY and runs a command', (tester) async {
    if (skipUnlessWindows('cmd.exe')) return;
    final output = await runInPty('cmd.exe', ['/c', 'echo PTY_OK']);
    expect(output, contains('PTY_OK'), reason: 'cmd.exe did not run');
  }, timeout: const Timeout(Duration(seconds: 40)));

  testWidgets('WSL default distro starts in a PTY', (tester) async {
    if (!await hasWslDistribution()) {
      // A skip, not a `return`: returning made this a green pass on every host
      // without WSL, which read as coverage it never had.
      markTestSkipped(
        'wsl.exe lists no distribution on this host, so there is nothing to '
        'start a PTY in.',
      );
      return;
    }
    final output = await runInPty('wsl.exe', ['--', 'echo', 'PTY_OK']);
    expect(output, contains('PTY_OK'), reason: 'wsl.exe did not run');
  }, timeout: const Timeout(Duration(seconds: 40)));
}
