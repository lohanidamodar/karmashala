import 'dart:async';
import 'dart:io';

import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import '../domain/browser_failure.dart';
import 'chrome_discovery.dart';
import 'devtools_http_endpoint.dart';

/// How we got hold of the browser we are driving.
enum BrowserConnectionMode {
  /// Attached to a browser the user already had listening on the port.
  attached,

  /// Launched our own browser because nothing was listening.
  spawned,
}

/// A live debugging endpoint plus how it came to exist.
class BrowserEndpoint {
  const BrowserEndpoint({
    required this.port,
    required this.mode,
    required this.http,
    this.executable,
    this.userDataDir,
    this.process,
  });

  final int port;
  final BrowserConnectionMode mode;
  final DevToolsHttpEndpoint http;

  /// The browser binary we spawned, when [mode] is
  /// [BrowserConnectionMode.spawned].
  final String? executable;

  /// The throwaway profile directory we spawned with. Never the user's own.
  final String? userDataDir;

  /// The spawned process, so the caller can shut it down again.
  final ProcessHandle? process;

  /// One line describing the connection, for the UI and for logs.
  String get description => switch (mode) {
    BrowserConnectionMode.attached =>
      'Attached to the browser already listening on port $port',
    BrowserConnectionMode.spawned =>
      'Launched ${executable ?? 'a browser'} on port $port with an isolated '
          'profile',
  };
}

/// Finds a debuggable browser: **attach first, spawn only as a fallback**.
///
/// Attaching is preferred because it drives the browser the user is actually
/// looking at, with their session, their extensions and their logged-in state.
/// Spawning is the fallback when nothing is listening, and it always uses a
/// throwaway `--user-data-dir` so the user's real profile is never opened,
/// locked, or modified by us.
class BrowserLauncher {
  BrowserLauncher({
    required this.runner,
    String? Function()? locateExecutable,
    DevToolsHttpEndpoint Function(int port)? endpointFactory,
    Future<String> Function()? createUserDataDir,
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _locateExecutable = locateExecutable ?? locateChromeExecutable,
       _endpointFactory =
           endpointFactory ?? ((port) => DevToolsHttpEndpoint(port: port)),
       _createUserDataDir = createUserDataDir ?? _defaultUserDataDir;

  /// The port Chrome uses by default for `--remote-debugging-port`.
  static const int defaultPort = 9222;

  /// Runs the browser process; the single choke point for execution.
  final CommandRunner runner;

  /// How often the debugging port is re-probed while a spawn starts up.
  final Duration pollInterval;

  final String? Function() _locateExecutable;
  final DevToolsHttpEndpoint Function(int port) _endpointFactory;
  final Future<String> Function() _createUserDataDir;

  /// Connects to a debugging endpoint on [port].
  ///
  /// Throws [BrowserException] with, in order of what actually went wrong:
  /// [BrowserFailure.portInUse] (something else owns the port),
  /// [BrowserFailure.notRunning] (nothing listening and [spawnIfNeeded] is
  /// false), [BrowserFailure.chromeNotFound] (no browser installed), and
  /// [BrowserFailure.startupFailed] (spawned, but the port never opened).
  Future<BrowserEndpoint> connect({
    int port = defaultPort,
    bool spawnIfNeeded = true,
    String? initialUrl,
    Duration startupTimeout = const Duration(seconds: 25),
  }) async {
    final http = _endpointFactory(port);
    final state = await http.probe();

    switch (state) {
      case DevToolsEndpointState.available:
        return BrowserEndpoint(
          port: port,
          mode: BrowserConnectionMode.attached,
          http: http,
        );
      case DevToolsEndpointState.occupiedByOther:
        http.close();
        throw BrowserException(
          BrowserFailure.portInUse,
          describeBrowserFailure(BrowserFailure.portInUse, port: port),
        );
      case DevToolsEndpointState.notListening:
        break;
    }

    if (!spawnIfNeeded) {
      http.close();
      throw BrowserException(
        BrowserFailure.notRunning,
        describeBrowserFailure(BrowserFailure.notRunning, port: port),
      );
    }

    final executable = _locateExecutable();
    if (executable == null) {
      http.close();
      throwChromeNotFound();
    }

    final userDataDir = await _createUserDataDir();
    final ProcessHandle process;
    try {
      process = await runner.start(
        CommandRequest(
          executable: executable,
          arguments: chromeLaunchArguments(
            port: port,
            userDataDir: userDataDir,
            initialUrl: initialUrl,
          ),
        ),
      );
    } on CommandException catch (e) {
      http.close();
      throw BrowserException(
        BrowserFailure.startupFailed,
        describeBrowserFailure(
          BrowserFailure.startupFailed,
          port: port,
          detail: e.message,
        ),
        cause: e,
      );
    }

    // Drain both pipes: an undrained Chrome fills its stderr buffer and stalls.
    // The tail is kept because Chrome explains startup failures there.
    final diagnostics = <String>[];
    void record(String line) {
      diagnostics.add(line);
      if (diagnostics.length > 20) diagnostics.removeAt(0);
    }

    final drains = [
      process.stdoutLines.listen(record, onError: (Object _) {}),
      process.stderrLines.listen(record, onError: (Object _) {}),
    ];

    var exited = false;
    int? exitCode;
    unawaited(
      process.exitCode.then((code) {
        exited = true;
        exitCode = code;
      }, onError: (Object _) => exited = true),
    );

    final deadline = DateTime.now().add(startupTimeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        if (await http.probe() == DevToolsEndpointState.available) {
          return BrowserEndpoint(
            port: port,
            mode: BrowserConnectionMode.spawned,
            http: http,
            executable: executable,
            userDataDir: userDataDir,
            process: process,
          );
        }
        if (exited) {
          throw BrowserException(
            BrowserFailure.startupFailed,
            describeBrowserFailure(
              BrowserFailure.startupFailed,
              port: port,
              detail: _diagnosticDetail(exitCode, diagnostics),
            ),
          );
        }
      }
      throw BrowserException(
        BrowserFailure.startupFailed,
        describeBrowserFailure(
          BrowserFailure.startupFailed,
          port: port,
          detail: _diagnosticDetail(null, diagnostics),
        ),
      );
    } finally {
      for (final drain in drains) {
        unawaited(drain.cancel());
      }
    }
  }

  static String _diagnosticDetail(int? exitCode, List<String> diagnostics) {
    final parts = <String>[
      if (exitCode != null) 'it exited with code $exitCode',
      for (final line in diagnostics.reversed.take(3).toList().reversed)
        if (line.trim().isNotEmpty) line.trim(),
    ];
    return parts.join('; ');
  }

  /// A fresh, throwaway profile directory under the system temp directory.
  static Future<String> _defaultUserDataDir() async {
    final directory = await Directory.systemTemp.createTemp(
      'karmashala-cdp-profile-',
    );
    return directory.path;
  }
}
