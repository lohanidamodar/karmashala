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
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('PowerShell starts in a PTY and runs a command', (tester) async {
    final output = await runInPty('powershell.exe', [
      '-NoLogo',
      '-Command',
      'Write-Output PTY_OK',
    ]);
    expect(output, contains('PTY_OK'), reason: 'powershell.exe did not run');
  }, timeout: const Timeout(Duration(seconds: 40)));

  testWidgets('cmd.exe starts in a PTY and runs a command', (tester) async {
    final output = await runInPty('cmd.exe', ['/c', 'echo PTY_OK']);
    expect(output, contains('PTY_OK'), reason: 'cmd.exe did not run');
  }, timeout: const Timeout(Duration(seconds: 40)));

  testWidgets('WSL default distro starts in a PTY (if WSL is installed)', (
    tester,
  ) async {
    // Best-effort: skip cleanly when WSL is not available.
    final check = await Process.run('wsl.exe', ['-l', '-q']);
    if (check.exitCode != 0) {
      // ignore: avoid_print
      print('WSL not available — skipping.');
      return;
    }
    final output = await runInPty('wsl.exe', ['--', 'echo', 'PTY_OK']);
    expect(output, contains('PTY_OK'), reason: 'wsl.exe did not run');
  }, timeout: const Timeout(Duration(seconds: 40)));
}
