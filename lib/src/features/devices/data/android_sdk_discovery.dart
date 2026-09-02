import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/android_device.dart';

/// Path separator for [kind]. Windows and WSL paths are never mixed
/// (constraints 7 & 8), so the separator is chosen per environment, not per host.
String _sep(EnvironmentKind kind) => usesWindowsPaths(kind) ? r'\' : '/';

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
    case EnvironmentKind.localPosix:
      final home = env['HOME']?.trim();
      if (home != null && home.isNotEmpty) {
        // Android Studio's default on macOS; on Linux it is ~/Android/Sdk.
        // Both are offered because these are candidates, probed in order, and
        // the kind alone does not say which of the two POSIX hosts this is.
        add(_join(kind, [home, 'Library', 'Android', 'sdk']));
        add(_join(kind, [home, 'Android', 'Sdk']));
        add(_join(kind, [home, 'android-sdk']));
      }
      add('/usr/lib/android-sdk');
    case EnvironmentKind.wsl || EnvironmentKind.ssh:
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
  usesWindowsPaths(kind) ? 'adb.exe' : 'adb',
]);

/// The `emulator` executable inside an SDK [root].
String emulatorPathIn(String root, EnvironmentKind kind) => _join(kind, [
  root,
  'emulator',
  usesWindowsPaths(kind) ? 'emulator.exe' : 'emulator',
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

/// Marks a line of [environmentRequest]'s output as one of ours.
///
/// A login shell runs the user's profile, and profiles print things — a version
/// manager's banner, a fortune, a warning about a missing tool. Reading values
/// off line numbers would hand the SDK root whatever that noise happened to
/// say, so each value names itself and everything unmarked is ignored.
const kEnvMarker = '__karmashala_env:';

/// Command that prints every one of [names] with its value, in **one** shell.
///
/// One, not one per variable, and that is the whole point: on POSIX this is a
/// *login* shell — needed so `PATH` and `ANDROID_HOME` from `~/.profile` are
/// visible at all — and a login shell costs about 63ms on the owner's Mac
/// against 72ms for one that answers all three. Asked separately, reading three
/// variables cost 190ms of the device pane's first open.
CommandRequest environmentRequest(EnvironmentKind kind, List<String> names) =>
    switch (kind) {
      // `echo %VAR%` prints the literal `%VAR%` when unset; the caller treats
      // that as empty. No space before `&`, or the value picks up a trailing
      // one.
      EnvironmentKind.windowsNative => CommandRequest(
        executable: 'cmd',
        arguments: [
          '/c',
          [for (final n in names) 'echo $kEnvMarker$n=%$n%'].join('&'),
        ],
      ),
      EnvironmentKind.localPosix ||
      EnvironmentKind.wsl ||
      EnvironmentKind.ssh => CommandRequest(
        executable: 'bash',
        arguments: [
          '-lc',
          [for (final n in names) 'echo "$kEnvMarker$n=\$$n"'].join('; '),
        ],
      ),
    };

/// The values [environmentRequest] printed, by name.
///
/// Unmarked lines are dropped, and so is a Windows value that came back as the
/// literal `%NAME%` — that is `cmd`'s way of saying the variable is unset.
Map<String, String> parseEnvironmentOutput(String stdout) {
  final values = <String, String>{};
  for (final line in stdout.split(RegExp(r'[\r\n]+'))) {
    final marked = line.trim();
    if (!marked.startsWith(kEnvMarker)) continue;
    final body = marked.substring(kEnvMarker.length);
    final split = body.indexOf('=');
    if (split <= 0) continue;
    final name = body.substring(0, split);
    final value = body.substring(split + 1).trim();
    if (value.isEmpty || value == '%$name%') continue;
    values[name] = value;
  }
  return values;
}

/// Command that succeeds only when [path] is a runnable SDK tool.
///
/// The tool is **executed** (with a harmless version flag) rather than tested
/// for existence. That is deliberate on two counts: it proves the binary
/// actually runs rather than merely being present, and it avoids
/// `cmd /c if exist "..."`, whose nested quotes are mangled by Windows argument
/// escaping — that probe reported "missing" for an adb.exe that was really
/// there.
CommandRequest executableProbeRequest(String path, List<String> versionFlag) =>
    CommandRequest(executable: path, arguments: versionFlag);

/// Version flag that makes `adb` exit 0.
const List<String> kAdbVersionFlag = ['--version'];

/// Version flag that makes `emulator` exit 0.
const List<String> kEmulatorVersionFlag = ['-version'];

/// Command that locates `adb` on the PATH.
CommandRequest adbOnPathRequest(EnvironmentKind kind) => switch (kind) {
  EnvironmentKind.windowsNative => const CommandRequest(
    executable: 'where',
    arguments: ['adb'],
  ),
  // A login shell so PATH additions from ~/.profile are visible, matching how
  // agent CLIs are discovered.
  EnvironmentKind.localPosix ||
  EnvironmentKind.wsl ||
  EnvironmentKind.ssh => const CommandRequest(
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
      if (await _isRunnable(adb, kAdbVersionFlag)) {
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
    final hasEmulator = await _isRunnable(emulator, kEmulatorVersionFlag);
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
      EnvironmentKind.localPosix ||
      EnvironmentKind.wsl ||
      EnvironmentKind.ssh => const ['ANDROID_HOME', 'ANDROID_SDK_ROOT', 'HOME'],
    };
    final output = await _runOrNull(environmentRequest(_kind, names));
    return output == null ? const {} : parseEnvironmentOutput(output);
  }

  /// Whether [path] runs. A missing executable surfaces as a [CommandException]
  /// from the runner, which reads as "not installed" rather than an error.
  Future<bool> _isRunnable(String path, List<String> versionFlag) async {
    try {
      final result = await runner.run(
        executableProbeRequest(path, versionFlag),
      );
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
