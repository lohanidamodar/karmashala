import 'dart:io';
import 'dart:math';

/// Shared plumbing for the `live-wsl` tests: the pty layer is FFI to a libc that
/// does not exist on the machine running the gate, so nothing can stand in.
class WslHarness {
  WslHarness._(this.distribution, this.binary);

  final String distribution;
  final File binary;

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

  /// `dart compile exe` is the only route: the Flutter cache carries no Linux
  /// `dartaotruntime`.
  static WslHarness prepare() {
    final out = File('build/karmashala_host-linux-x64');
    if (!out.existsSync()) {
      out.parent.createSync(recursive: true);
      final dart = Platform.resolvedExecutable;
      final result = Process.runSync(dart, [
        'compile',
        'exe',
        'bin/karmashala_host.dart',
        '--target-os=linux',
        '--target-arch=x64',
        '-o',
        out.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('cross-compile failed: ${result.stdout}${result.stderr}');
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

  /// Copied into the distribution's own filesystem first: DrvFs cannot carry
  /// the execute bit.
  String installScript(String target) => '''
mkdir -p "\$(dirname $target)"
cp ${toWslPath(binary.path)} $target
chmod +x $target
''';

  /// Scripts travel as a file, never as `sh -c`: a multi-line script with quotes
  /// does not survive Windows rebuilding the command line. The name must be
  /// unique across isolates — pid plus a static counter collides, silently.
  ProcessResult runSync(String script) {
    final tag = '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
    final file = File('${binary.parent.path}/wsl-script-$tag.sh')
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
