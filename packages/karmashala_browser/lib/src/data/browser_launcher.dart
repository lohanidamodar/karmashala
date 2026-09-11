import 'dart:async';
import 'dart:io';

import '../domain/browser_failure.dart';
import 'browser_process.dart';
import 'chrome_discovery.dart';
import 'devtools_http_endpoint.dart';

enum BrowserConnectionMode {
  /// Attached to a browser the user already had listening on the port.
  attached,

  /// Launched our own browser because nothing was listening.
  spawned,
}

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
  final BrowserProcess? process;

  String get description => switch (mode) {
    BrowserConnectionMode.attached =>
      'Attached to the browser already listening on port $port',
    BrowserConnectionMode.spawned =>
      'Launched ${executable ?? 'a browser'} on port $port with an isolated '
          'profile',
  };

  /// Ends a spawned browser and removes its throwaway profile. Nothing to do
  /// for an attached one: that browser and profile are the user's.
  Future<void> shutDown({
    Duration exitTimeout = const Duration(seconds: 5),
  }) async {
    if (mode != BrowserConnectionMode.spawned) return;
    await killAndDiscardProfile(process, userDataDir, exitTimeout: exitTimeout);
  }
}

/// Kills [process] and, once it has exited (Chrome holds the profile lock until
/// then), deletes [userDataDir]. Either half missing is skipped, not an error.
Future<void> killAndDiscardProfile(
  BrowserProcess? process,
  String? userDataDir, {
  Duration exitTimeout = const Duration(seconds: 5),
}) async {
  if (process != null) {
    try {
      await process.kill();
      await process.exitCode.timeout(exitTimeout);
    } on Object {
      // Already gone, or not going: the profile is still ours to try.
    }
  }
  if (userDataDir == null) return;
  try {
    final directory = Directory(userDataDir);
    if (await directory.exists()) await directory.delete(recursive: true);
  } on Object {
    // A locked profile is left for the next sweep rather than failing the caller.
  }
}

/// Finds a debuggable browser: attach first, spawn only as a fallback.
/// Attaching drives the browser the user is looking at; a spawn always uses a
/// throwaway `--user-data-dir`, so their real profile is never opened or locked.
class BrowserLauncher {
  BrowserLauncher({
    required this.startProcess,
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

  /// Spawns the browser; the single choke point for execution.
  final BrowserProcessStarter startProcess;

  /// How often the debugging port is re-probed while a spawn starts up.
  final Duration pollInterval;

  final String? Function() _locateExecutable;
  final DevToolsHttpEndpoint Function(int port) _endpointFactory;
  final Future<String> Function() _createUserDataDir;

  /// Connects to a debugging endpoint on [port]. Throws [BrowserException]:
  /// portInUse, notRunning (nothing there and [spawnIfNeeded] false),
  /// chromeNotFound, or startupFailed (spawned, but the port never opened).
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
    final BrowserProcess process;
    try {
      process = await startProcess(
        executable,
        chromeLaunchArguments(
          port: port,
          userDataDir: userDataDir,
          initialUrl: initialUrl,
        ),
      );
    } on Object catch (e) {
      // Anything the starter throws means the browser never ran, which is one
      // failure with one remedy; its own text is the useful half.
      http.close();
      await killAndDiscardProfile(null, userDataDir);
      throw BrowserException(
        BrowserFailure.startupFailed,
        describeBrowserFailure(
          BrowserFailure.startupFailed,
          port: port,
          detail: '$e',
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
    var succeeded = false;
    try {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        if (await http.probe() == DevToolsEndpointState.available) {
          succeeded = true;
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
      // A browser that never opened its port is still running, on a profile
      // nobody will ever open again.
      if (!succeeded) {
        http.close();
        await killAndDiscardProfile(process, userDataDir);
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
