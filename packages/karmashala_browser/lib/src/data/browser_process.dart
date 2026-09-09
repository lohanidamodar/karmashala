import 'dart:async';

/// A browser process this package asked for, reduced to what the launcher
/// reads from it.
///
/// The app drives every process through `CommandRunner`/`ProcessHandle`, whose
/// request type carries an `EnvironmentPath` and so reaches back into the app's
/// environments layer. A browser is always spawned on the machine the app runs
/// on, so nothing here needs that: the launcher wants two line streams, an exit
/// code and a way to stop it, and the app passes an adapter over its own runner.
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

/// Starts [executable] with [arguments] and returns a handle to it.
///
/// Throws when the process cannot be started at all — a missing binary, a
/// refused spawn. [BrowserLauncher] reports any such throw as
/// [BrowserFailure.startupFailed] and carries the message through, so the
/// exception type is the caller's to choose; [BrowserProcessException] is here
/// for callers that have no richer one.
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
