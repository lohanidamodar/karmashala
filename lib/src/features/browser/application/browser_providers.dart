import 'package:karmashala_browser/browser.dart';
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';

/// The debugging port Karmashala attaches to (or launches a browser on).
///
/// Chrome's own default, so a browser the user started with
/// `--remote-debugging-port=9222` — and, since Chrome 136, its own
/// `--user-data-dir` — is found without configuring anything.
final browserDebugPortProvider = Provider<int>(
  (ref) => BrowserLauncher.defaultPort,
);

/// A [ProcessHandle] seen as the four things [BrowserLauncher] reads from it.
class _HandleAsBrowserProcess implements BrowserProcess {
  const _HandleAsBrowserProcess(this._handle);

  final ProcessHandle _handle;

  @override
  Stream<String> get stdoutLines => _handle.stdoutLines;

  @override
  Stream<String> get stderrLines => _handle.stderrLines;

  @override
  Future<int> get exitCode => _handle.exitCode;

  @override
  Future<void> kill() => _handle.kill();
}

/// The app's side of `karmashala_browser`'s process seam.
///
/// The package spawns nothing itself — it takes a [BrowserProcessStarter] — so
/// that its launcher does not need `CommandRequest`, whose `EnvironmentPath`
/// belongs to the environments layer for a process that is always local. This
/// is the one adapter that closes it, and every construction of a
/// [BrowserService] in the app goes through it.
///
/// A [CommandException] is re-thrown as a [BrowserProcessException] carrying
/// its message alone, so the startup failure the launcher reports reads exactly
/// as it did when it caught the runner's own exception.
BrowserProcessStarter browserProcessStarter(CommandRunner runner) =>
    (String executable, List<String> arguments) async {
      try {
        return _HandleAsBrowserProcess(
          await runner.start(
            CommandRequest(executable: executable, arguments: arguments),
          ),
        );
      } on CommandException catch (e) {
        throw BrowserProcessException(e.message, cause: e);
      }
    };

/// The browser driver.
///
/// Kept as a single long-lived service because a session owns a WebSocket and
/// possibly a spawned process; disposing the provider tears both down.
final browserServiceProvider = Provider<BrowserService>((ref) {
  final service = BrowserService(
    startProcess: browserProcessStarter(ref.watch(hostCommandRunnerProvider)),
  );
  ref.onDispose(() => service.disconnect());
  return service;
});
