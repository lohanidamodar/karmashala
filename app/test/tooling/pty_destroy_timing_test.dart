@TestOn('windows')
@Tags(['live-timing'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `pty_destroy` against a **real** ConPTY, timed.
///
/// `pty_destroy_contract_test.dart` reads the C and says the close is handed to
/// a worker. This runs it and says how long the call took, which is the only
/// form of the claim the 2026-09-10 hang can be argued against: the minidump
/// showed the app's main thread inside `flutter_pty.dll!pty_destroy` with four
/// headless console hosts alive, and no amount of source reading would have
/// predicted the number.
///
/// Measured on the owner's machine 2026-09-10, against a child that swallows
/// `CTRL_CLOSE_EVENT` (see `conpty_destroy_harness.c`):
///
/// ```txt
///   before  destroy_ms=5005.0  child_gone_ms=5006.1
///   after   destroy_ms=1.4     child_gone_ms=5016.0
/// ```
///
/// The five seconds did not go away — that is Windows' own grace period before
/// it ends a process that ignored the close — they stopped being spent on the
/// caller's thread. A child that never goes turns those five seconds into
/// forever, which is what the app was doing when the dump was taken.
///
/// Three things it needs, and it says which is missing rather than failing:
/// Windows, an MSVC toolchain (the plugin's DLL only exists inside a built app,
/// so like `pty_fd_lifecycle_test.dart` this compiles the C itself), and
/// `KARMASHALA_TIMING` — a wall-clock reading is a measurement of the machine
/// as much as of the code, which is what the `live-timing` tag is for.
void main() {
  test('pty_destroy returns while the console is still closing', () async {
    if (Platform.environment['KARMASHALA_TIMING'] == null) {
      markTestSkipped('set KARMASHALA_TIMING to measure');
      return;
    }

    final vcvars = await _vcvars();
    if (vcvars == null) {
      markTestSkipped('no MSVC toolchain found');
      return;
    }

    final work = await Directory.systemTemp.createTemp('conpty_destroy');
    addTearDown(() => work.delete(recursive: true));

    if (work.path.contains(' ')) {
      // `build_command` in the plugin quotes nothing, so the harness would
      // spawn the wrong thing and the number would be a lie.
      markTestSkipped('temp path contains a space: ${work.path}');
      return;
    }

    final binary = '${work.path}\\conpty_destroy_harness.exe';
    const src = r'packages\flutter_pty\src';
    final script = File('${work.path}\\build.bat');
    await script.writeAsString(
      '@echo off\r\n'
      'call "$vcvars" >nul\r\n'
      'cd /d "${Directory.current.path}"\r\n'
      'cl /nologo /W3 /I $src '
      r'packages\flutter_pty\test\conpty_destroy_harness.c '
      '$src\\flutter_pty_win.c $src\\include\\dart_api_dl.c '
      '/Fe:$binary /Fo:${work.path}\\ /link kernel32.lib\r\n',
    );

    // Through `cmd.exe`: `CreateProcess` does not run a `.bat` on its own, and
    // the toolchain only exists inside the environment `vcvars64.bat` sets up.
    final build = await Process.run('cmd.exe', ['/c', script.path]);
    expect(
      build.exitCode,
      0,
      reason: 'harness did not build:\n${build.stdout}\n${build.stderr}',
    );

    // The harness bounds itself: ~2.5 s of waiting for conhost and the child's
    // handler, then at most 10 s watching for the child to go, and it kills
    // anything still standing. This is the outer bound on all of that.
    final run = await Process.run(
      binary,
      const [],
    ).timeout(const Duration(seconds: 60));

    final output = '${run.stdout}';
    final destroyMs = _reading(output, 'destroy_ms');
    final childGoneMs = _reading(output, 'child_gone_ms');

    expect(
      run.exitCode,
      0,
      reason: 'the harness rejected its own reading: $output${run.stderr}',
    );

    // The contract, generous by three orders of magnitude against the failure
    // it guards -- which is not "slow" but "never".
    expect(
      destroyMs,
      lessThan(100),
      reason:
          'pty_destroy blocked for ${destroyMs}ms. Whoever calls it may be the '
          'platform thread.',
    );

    // And the release really was still happening. Without this the test would
    // pass just as happily against a console that closed instantly, which is
    // not the case anybody was hurt by.
    expect(
      childGoneMs,
      greaterThan(destroyMs * 10),
      reason:
          'the harness child was meant to hold its console host open and did '
          'not (${childGoneMs}ms), so this run proves nothing about deferral',
    );
  });
}

/// The number the harness printed for [name].
double _reading(String output, String name) {
  final match = RegExp('$name=(-?[0-9.]+)').firstMatch(output);
  expect(match, isNotNull, reason: 'no $name in harness output: $output');
  return double.parse(match!.group(1)!);
}

/// The newest `vcvars64.bat`, or null when there is no MSVC to find.
///
/// Through `vswhere` — the only supported way to locate a Visual Studio
/// install, and the reason this does not hard-code a version that the next
/// update moves. §20's rule: the check is the durable half, the path is not.
Future<String?> _vcvars() async {
  final programFiles =
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
  final vswhere = File(
    '$programFiles\\Microsoft Visual Studio\\Installer\\vswhere.exe',
  );
  if (!vswhere.existsSync()) return null;

  final found = await Process.run(vswhere.path, const [
    '-latest',
    '-products',
    '*',
    '-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '-find',
    r'VC\Auxiliary\Build\vcvars64.bat',
  ]);
  if (found.exitCode != 0) return null;

  final path = '${found.stdout}'.trim().split('\n').first.trim();
  return path.isEmpty || !File(path).existsSync() ? null : path;
}
