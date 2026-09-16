import 'dart:io';
import 'dart:math';

/// Shared plumbing for the `live-wsl` tests: the pty layer is FFI to a libc that
/// does not exist on the machine running the gate, so nothing can stand in.
class WslHarness {
  WslHarness._(this.distribution, this.bundle);

  final String distribution;

  /// The `bundle/` directory `dart build cli` writes: `bin/` beside `lib/`.
  /// A directory rather than a file since 2026-09-15 — see [prepare].
  final Directory bundle;

  /// The executable inside an installed bundle rooted at [target].
  static String executableIn(String target) => '$target/bin/karmashala_host';

  static const _distribution = 'archlinux';

  /// Null when this machine has no WSL, so a test skips with a reason.
  static String? unavailableReason() {
    if (!Platform.isWindows) return 'live-wsl needs Windows with WSL';
    final probe = Process.runSync('wsl.exe', ['-d', _distribution, '--', 'true']);
    if (probe.exitCode != 0) {
      return 'wsl -d $_distribution is not runnable (exit ${probe.exitCode})';
    }
    return null;
  }

  /// `dart build cli`, not `dart compile exe`: the host depends on `sqlite3`,
  /// whose build hook `dart compile` refuses outright. The output is a bundle —
  /// the executable beside the SQLite it was built with.
  ///
  /// **A bundle cross-compiled here cannot open a store**, measured 2026-09-15:
  /// the bundled library's relative path is written with the *building*
  /// machine's separator, so a Linux binary built on Windows hunts for
  /// `..\lib\libsqlite3.so` and `probe-store` answers `STORE MISLINKED`. The pty
  /// layer these tests exercise never touches SQLite, so it is unaffected — but
  /// nothing here may assume a cross-compiled host can hold sessions.
  static WslHarness prepare() {
    final out = Directory('build/cli/linux_x64/bundle');
    if (!File(executableIn(out.path)).existsSync()) {
      final result = Process.runSync(Platform.resolvedExecutable, [
        'build',
        'cli',
        '-t',
        'bin/karmashala_host.dart',
        '--target-os=linux',
        '--target-arch=x64',
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'cross-build failed: ${result.stdout}${result.stderr}',
        );
      }
    }
    return WslHarness._(_distribution, out.absolute);
  }

  /// `C:\kw\...` as the distribution sees it. DrvFs is mounted at `/mnt/<drive>`.
  static String toWslPath(String windowsPath) {
    final normalised = windowsPath.replaceAll(r'\', '/');
    final drive = RegExp(r'^([A-Za-z]):/').firstMatch(normalised);
    if (drive == null) return normalised;
    return '/mnt/${drive.group(1)!.toLowerCase()}/${normalised.substring(3)}';
  }

  /// Installs the whole bundle under [target], so `bin/` keeps `lib/` beside it
  /// and the executable can find the library it was built with. Copied into the
  /// distribution's own filesystem first: DrvFs cannot carry the execute bit.
  String installScript(String target) => '''
rm -rf $target
mkdir -p $target
cp -r ${toWslPath(bundle.path)}/. $target/
chmod +x ${executableIn(target)}
''';

  /// Scripts travel as a file, never as `sh -c`: a multi-line script with quotes
  /// does not survive Windows rebuilding the command line. The name must be
  /// unique across isolates — pid plus a static counter collides, silently.
  ProcessResult runSync(String script) {
    final tag = '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
    final file = File('${bundle.parent.path}/wsl-script-$tag.sh')
      ..writeAsStringSync(script.replaceAll('\r\n', '\n'));
    final result = Process.runSync('wsl.exe', ['-d', distribution, '--', 'sh', toWslPath(file.path)]);
    file.deleteSync();
    return result;
  }

  /// Same, but a non-zero exit fails the set-up rather than an assertion later.
  void runOrThrow(String script) {
    final result = runSync(script);
    if (result.exitCode != 0) {
      throw StateError('wsl script failed (${result.exitCode}): ${result.stdout}${result.stderr}');
    }
  }

  static final _random = Random();

  Future<Process> start(List<String> argv) =>
      Process.start('wsl.exe', ['-d', distribution, '--', ...argv]);
}
