import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
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

/// The field of the app's settings (`settings.v1`) that names an Android SDK
/// by hand. Read by the pane and by the server alike (slice 4a).
const String kAndroidSdkPathSetting = 'androidSdkPath';

/// The Android SDK a person named in the decoded settings [settings], or null.
String? androidSdkPathIn(Object? settings) {
  if (settings is! Map) return null;
  final value = settings[kAndroidSdkPathSetting];
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

/// Ordered SDK root candidates for [kind], given the environment variables [env]
/// read from that environment. **The one rule every adb user on a machine
/// follows** — the pane, the server's tools and `flutter run` must reach the
/// same adb, because two adb versions restart each other's daemon: [handSet]
/// (the `androidSdkPath` setting) first, then `ANDROID_HOME`, then
/// `ANDROID_SDK_ROOT`, then the platform default; `adb` on the PATH is the
/// discovery's last resort. Blank values are ignored: unset often expands to
/// empty. `ANDROID_ADB_SERVER_PORT` is never used — one daemon, its own port.
List<String> sdkCandidateRoots({
  required EnvironmentKind kind,
  required Map<String, String> env,
  String? handSet,
}) {
  final roots = <String>[];
  void add(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (roots.contains(trimmed)) return;
    roots.add(trimmed);
  }

  add(handSet);
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
        // Android Studio's default on macOS; on Linux it is ~/Android/Sdk. Both
        // are offered because the kind alone does not say which POSIX host.
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

/// Marks a line of [environmentRequest]'s output as one of ours. A login shell
/// runs the user's profile, and profiles print things, so each value names
/// itself and everything unmarked is ignored.
const kEnvMarker = '__karmashala_env:';

/// Command that prints every one of [names] with its value, in **one** shell.
/// One, not one per variable: on POSIX this is a *login* shell, and asking
/// separately cost 190 ms of the device pane's first open.
///
/// [loginShell] overrides the local host's shell, so the branch is testable
/// without depending on the shell of whoever runs the suite.
CommandRequest environmentRequest(
  EnvironmentKind kind,
  List<String> names, {
  String? loginShell,
}) => switch (kind) {
  // `echo %VAR%` prints the literal `%VAR%` when unset; the caller treats
  // that as empty. No space before `&`, or the value gains a trailing one.
  EnvironmentKind.windowsNative => CommandRequest(
    executable: 'cmd',
    arguments: [
      '/c',
      [for (final n in names) 'echo $kEnvMarker$n=%$n%'].join('&'),
    ],
  ),
  // The **owner's** shell on the local host, `bash` elsewhere. On a Mac
  // that is zsh, and `bash -l` there reads `~/.bash_profile` and never
  // `~/.zprofile`, so a hardcoded bash could not see an `ANDROID_HOME` the
  // user's terminal shows them. Still a login shell rather than an
  // interactive one: this runs on every device probe, and the miss it
  // cannot cover — a variable set only in `~/.zshrc` — is covered by the
  // `adb` lookup, which does take the interactive second look.
  EnvironmentKind.localPosix => CommandRequest(
    executable: loginShell ?? localLoginShell(),
    arguments: [
      '-lc',
      [for (final n in names) 'echo "$kEnvMarker$n=\$$n"'].join('; '),
    ],
  ),
  EnvironmentKind.wsl || EnvironmentKind.ssh => CommandRequest(
    executable: 'bash',
    arguments: [
      '-lc',
      [for (final n in names) 'echo "$kEnvMarker$n=\$$n"'].join('; '),
    ],
  ),
};

/// The values [environmentRequest] printed, by name. Unmarked lines are dropped,
/// and so is a Windows value of the literal `%NAME%` — `cmd` for "unset".
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

/// Command that succeeds only when [path] is a runnable SDK tool. The tool is
/// **executed** with a harmless version flag: it proves the binary runs, and it
/// avoids `cmd /c if exist`, whose nested quotes Windows escaping mangles.
CommandRequest executableProbeRequest(String path, List<String> versionFlag) =>
    CommandRequest(executable: path, arguments: versionFlag);

/// Version flag that makes `adb` exit 0.
const List<String> kAdbVersionFlag = ['--version'];

/// Version flag that makes `emulator` exit 0.
const List<String> kEmulatorVersionFlag = ['-version'];

/// Locates the Android SDK in one execution environment: `ANDROID_HOME`,
/// `ANDROID_SDK_ROOT`, the default location, then `adb` on the PATH. Everything
/// runs through [runner], so a WSL SDK is probed inside WSL — the two adb
/// servers are different and their device lists are not interchangeable.
class AndroidSdkDiscoveryService {
  AndroidSdkDiscoveryService({
    required this.runner,
    required this.environment,
    this.handSetRoot,
  });

  final CommandRunner runner;
  final ExecutionEnvironment environment;

  /// The SDK root a person named (`androidSdkPath`), tried before anything
  /// the environment says. See [sdkCandidateRoots].
  final String? handSetRoot;

  EnvironmentKind get _kind => environment.kind;

  Future<AndroidSdk?> discover() async {
    final env = await _readEnvironmentVariables();
    for (final root in sdkCandidateRoots(
      kind: _kind,
      env: env,
      handSet: handSetRoot,
    )) {
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

  /// Whether [path] runs. A missing executable surfaces as a [CommandException],
  /// which reads as "not installed" rather than an error.
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

  /// `adb` wherever the owner's own terminal would find it.
  ///
  /// Through [locateOnPath] rather than a bare login shell: the Android SDK's
  /// `platform-tools` is almost always added to PATH in `~/.zshrc`, which a
  /// login shell never reads, so an app launched from Finder — inheriting
  /// launchd's four-entry PATH — found no `adb` on this machine at all while it
  /// worked perfectly in the owner's terminal. Measured 2026-09-16:
  /// `bash -lc 'command -v adb'` exits 1, the interactive probe answers
  /// `~/Library/Android/sdk/platform-tools/adb`.
  ///
  /// An unreachable environment reads as "no SDK here", the same rule
  /// [_runOrNull] applies to every other probe in this service — [locateOnPath]
  /// raises instead of deciding that, because a toolchain panel has to tell the
  /// two apart and this does not.
  Future<String?> _adbOnPath() async {
    try {
      return await locateOnPath(runner, _kind, const ['adb']);
    } on CommandException {
      return null;
    }
  }

  /// Runs [request], returning stdout on success and `null` on any failure —
  /// including an unavailable environment, which must read as "no SDK here".
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
