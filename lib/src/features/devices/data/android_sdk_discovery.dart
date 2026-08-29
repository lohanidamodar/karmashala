import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/android_device.dart';

/// Path separator for [kind]. Windows and WSL paths are never mixed
/// (constraints 7 & 8), so the separator is chosen per environment, not per host.
String _sep(EnvironmentKind kind) =>
    kind == EnvironmentKind.windowsNative ? r'\' : '/';

String _join(EnvironmentKind kind, List<String> parts) {
  final sep = _sep(kind);
  return parts
      .map((p) => p.endsWith(sep) ? p.substring(0, p.length - 1) : p)
      .join(sep);
}

/// Ordered SDK root candidates for [kind], given the environment variables
/// [env] read from that environment.
///
/// `ANDROID_HOME` wins, then the deprecated-but-common `ANDROID_SDK_ROOT`, then
/// the platform's default install location. Blank values are ignored — an
/// unset variable often expands to an empty string rather than being absent.
List<String> sdkCandidateRoots({
  required EnvironmentKind kind,
  required Map<String, String> env,
}) {
  final roots = <String>[];
  void add(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (roots.contains(trimmed)) return;
    roots.add(trimmed);
  }

  add(env['ANDROID_HOME']);
  add(env['ANDROID_SDK_ROOT']);

  switch (kind) {
    case EnvironmentKind.windowsNative:
      final localAppData = env['LOCALAPPDATA']?.trim();
      if (localAppData != null && localAppData.isNotEmpty) {
        add(_join(kind, [localAppData, 'Android', 'Sdk']));
      }
    case EnvironmentKind.wsl:
      final home = env['HOME']?.trim();
      if (home != null && home.isNotEmpty) {
        add(_join(kind, [home, 'Android', 'Sdk']));
        add(_join(kind, [home, 'android-sdk']));
      }
      add('/usr/lib/android-sdk');
  }
  return roots;
}

/// The `adb` executable inside an SDK [root].
String adbPathIn(String root, EnvironmentKind kind) => _join(kind, [
  root,
  'platform-tools',
  kind == EnvironmentKind.windowsNative ? 'adb.exe' : 'adb',
]);

/// The `emulator` executable inside an SDK [root].
String emulatorPathIn(String root, EnvironmentKind kind) => _join(kind, [
  root,
  'emulator',
  kind == EnvironmentKind.windowsNative ? 'emulator.exe' : 'emulator',
]);

/// Derives the SDK root from a located `adb` path
/// (`<root>/platform-tools/adb[.exe]` → `<root>`), or `null` if the layout is
/// unexpected.
String? sdkRootFromAdbPath(String adbPath, EnvironmentKind kind) {
  final sep = _sep(kind);
  final parts = adbPath.split(RegExp(r'[\\/]'));
  if (parts.length < 3) return null;
  // Drop the executable and the platform-tools directory.
  final trimmed = parts.sublist(0, parts.length - 2);
  if (trimmed.isEmpty) return null;
  return trimmed.join(sep);
}

/// Command that prints an environment variable's value in [kind].
CommandRequest envRequest(EnvironmentKind kind, String name) => switch (kind) {
  // `cmd /c echo %VAR%` prints the literal `%VAR%` when unset; the caller
  // treats that as empty.
  EnvironmentKind.windowsNative => CommandRequest(
    executable: 'cmd',
    arguments: ['/c', 'echo %$name%'],
  ),
  EnvironmentKind.wsl => CommandRequest(
    executable: 'bash',
    arguments: ['-lc', 'echo \$$name'],
  ),
};

/// Command that succeeds only when [path] is an executable file in [kind].
CommandRequest executableProbeRequest(EnvironmentKind kind, String path) =>
    switch (kind) {
      EnvironmentKind.windowsNative => CommandRequest(
        executable: 'cmd',
        arguments: ['/c', 'if exist "$path" (exit 0) else (exit 1)'],
      ),
      EnvironmentKind.wsl => CommandRequest(
        executable: 'bash',
        arguments: ['-lc', 'test -x "$path"'],
      ),
    };

/// Command that locates `adb` on the PATH.
CommandRequest adbOnPathRequest(EnvironmentKind kind) => switch (kind) {
  EnvironmentKind.windowsNative => const CommandRequest(
    executable: 'where',
    arguments: ['adb'],
  ),
  // A login shell so PATH additions from ~/.profile are visible, matching how
  // agent CLIs are discovered.
  EnvironmentKind.wsl => const CommandRequest(
    executable: 'bash',
    arguments: ['-lc', 'command -v adb'],
  ),
};

/// Locates the Android SDK in one execution environment.
///
/// Order: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, the platform's default install
/// location, then `adb` on the PATH (from which the root is derived). Everything
/// runs through the supplied [runner] (constraint 6), so a WSL SDK is probed
/// inside WSL and a Windows SDK on Windows — the two adb servers are different
/// and their device lists are not interchangeable.
class AndroidSdkDiscoveryService {
  AndroidSdkDiscoveryService({required this.runner, required this.environment});

  final CommandRunner runner;
  final ExecutionEnvironment environment;

  EnvironmentKind get _kind => environment.kind;

  Future<AndroidSdk?> discover() async {
    final env = await _readEnvironmentVariables();
    for (final root in sdkCandidateRoots(kind: _kind, env: env)) {
      final adb = adbPathIn(root, _kind);
      if (await _isExecutable(adb)) {
        return _sdkAt(root, adb);
      }
    }
    // Nothing at a known location — fall back to whatever is on the PATH.
    final onPath = await _adbOnPath();
    if (onPath != null) {
      final root = sdkRootFromAdbPath(onPath, _kind);
      if (root != null) return _sdkAt(root, onPath);
    }
    return null;
  }

  Future<AndroidSdk> _sdkAt(String root, String adbPath) async {
    final emulator = emulatorPathIn(root, _kind);
    final hasEmulator = await _isExecutable(emulator);
    return AndroidSdk(
      root: EnvironmentPath(environmentId: environment.id, path: root),
      adb: EnvironmentPath(environmentId: environment.id, path: adbPath),
      emulator: hasEmulator
          ? EnvironmentPath(environmentId: environment.id, path: emulator)
          : null,
    );
  }

  Future<Map<String, String>> _readEnvironmentVariables() async {
    final names = switch (_kind) {
      EnvironmentKind.windowsNative => const [
        'ANDROID_HOME',
        'ANDROID_SDK_ROOT',
        'LOCALAPPDATA',
      ],
      EnvironmentKind.wsl => const ['ANDROID_HOME', 'ANDROID_SDK_ROOT', 'HOME'],
    };
    final env = <String, String>{};
    for (final name in names) {
      final value = await _runOrNull(envRequest(_kind, name));
      if (value == null) continue;
      final trimmed = value.trim();
      // `cmd /c echo %VAR%` echoes the literal when the variable is unset.
      if (trimmed.isEmpty || trimmed == '%$name%') continue;
      env[name] = trimmed;
    }
    return env;
  }

  Future<bool> _isExecutable(String path) async {
    try {
      final result = await runner.run(executableProbeRequest(_kind, path));
      return result.ok;
    } on CommandException {
      return false;
    }
  }

  Future<String?> _adbOnPath() async {
    final output = await _runOrNull(adbOnPathRequest(_kind));
    if (output == null) return null;
    for (final line in output.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// Runs [request], returning stdout on success and `null` on any failure —
  /// including an unavailable environment (e.g. WSL not running), which must
  /// read as "no SDK here" rather than crash discovery.
  Future<String?> _runOrNull(CommandRequest request) async {
    try {
      final result = await runner.run(request);
      if (!result.ok) return null;
      return result.stdout;
    } on CommandException {
      return null;
    }
  }
}
