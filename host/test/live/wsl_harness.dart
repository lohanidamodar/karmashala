import 'dart:io';

/// Shared plumbing for the `live-wsl` tests: they cross-compile the host and
/// drive the real binary inside a real distribution, because the pty layer is
/// FFI to a libc that does not exist on the machine running the gate.
class WslHarness {
  WslHarness._(this.distribution, this.binary);

  final String distribution;
  final File binary;

  static const _distribution = 'archlinux';

  /// Null when this machine cannot answer — no WSL, or no distribution — so a
  /// test skips with a reason instead of failing for the machine's shape.
  static String? unavailableReason() {
    if (!Platform.isWindows) return 'live-wsl needs Windows with WSL';
    final probe = Process.runSync('wsl.exe', ['-d', _distribution, '--', 'true']);
    if (probe.exitCode != 0) {
      return 'wsl -d $_distribution is not runnable (exit ${probe.exitCode})';
    }
    return null;
  }

  /// Compiles once per run and reuses the artefact; `dart compile exe` is the
  /// only route because the Flutter cache carries no Linux `dartaotruntime`.
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

  /// Copies the binary into the distribution's own filesystem before running
  /// it: DrvFs cannot carry the execute bit, and a host deployed for real
  /// lives under `~/.karmashala/bin` anyway.
  String installScript(String target) => '''
mkdir -p "\$(dirname $target)"
cp ${toWslPath(binary.path)} $target
chmod +x $target
''';

  ProcessResult runSync(String script) =>
      Process.runSync('wsl.exe', ['-d', distribution, '--', 'sh', '-c', script]);

  Future<Process> start(List<String> argv) =>
      Process.start('wsl.exe', ['-d', distribution, '--', ...argv]);
}
