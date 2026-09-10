import 'package:karmashala_browser/browser.dart';
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';

/// The debugging port Karmashala attaches to — Chrome's own default, so a
/// browser started with `--remote-debugging-port=9222` is found unconfigured.
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

/// The app's side of `karmashala_browser`'s process seam: the package spawns
/// nothing itself, so this is the one adapter that closes it.
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

/// The browser driver. One long-lived service, because a session owns a
/// WebSocket and possibly a spawned process; disposing tears both down.
final browserServiceProvider = Provider<BrowserService>((ref) {
  final service = BrowserService(
    startProcess: browserProcessStarter(ref.watch(hostCommandRunnerProvider)),
  );
  ref.onDispose(() => service.disconnect());
  return service;
});
