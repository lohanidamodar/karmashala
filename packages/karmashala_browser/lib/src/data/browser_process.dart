import 'dart:async';

/// A browser process, reduced to what the launcher reads from it. The app's own
/// `CommandRunner` request type carries an `EnvironmentPath`, which a browser —
/// always spawned on this machine — does not need, so the app passes an adapter.
abstract interface class BrowserProcess {
  /// Line-buffered stdout (decoded text, newline-stripped).
  Stream<String> get stdoutLines;

  /// Line-buffered stderr — where Chrome explains a failed start.
  Stream<String> get stderrLines;

  /// Completes with the process exit code.
  Future<int> get exitCode;

  /// Terminates the process.
  Future<void> kill();
}

/// Starts [executable] and returns a handle. Any throw is reported by
/// [BrowserLauncher] as startupFailed with the message carried through, so the
/// exception type is the caller's to choose.
typedef BrowserProcessStarter =
    Future<BrowserProcess> Function(String executable, List<String> arguments);

/// Raised when a browser process cannot be started.
class BrowserProcessException implements Exception {
  BrowserProcessException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
