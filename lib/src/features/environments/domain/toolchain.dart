import 'package:agent_cli/process.dart';

/// **What a machine needs before Karmashala can build anything on it.**
///
/// Not a list of nice-to-haves: each one is something the app really spawns —
/// `ProjectBuildTool` names the first four, and the fifth is what installing
/// and launching a build runs.
enum Toolchain {
  flutterSdk(
    label: 'Flutter SDK',
    purpose: 'Flutter apps, and the Flutter half of a React Native one',
    executable: 'flutter',
    windowsExecutable: 'flutter.bat',
    arguments: ['--version'],
  ),
  jdk(
    label: 'JDK',
    purpose: "what the project's own gradlew runs on",
    executable: 'java',
    arguments: ['-version'],
  ),
  androidPlatformTools(
    label: 'adb',
    purpose: 'installing and launching an Android build',
    executable: 'adb',
    arguments: ['version'],
  ),
  xcode(
    label: 'xcodebuild',
    purpose: 'iOS, on a Mac only',
    executable: 'xcodebuild',
    arguments: ['-version'],
  ),
  node(
    label: 'node',
    purpose: "running a project's own package script",
    executable: 'node',
    arguments: ['--version'],
  );

  const Toolchain({
    required this.label,
    required this.purpose,
    required this.executable,
    required this.arguments,
    this.windowsExecutable,
  });

  final String label;

  /// What it is *for*, in the words the catalogue used before it was folded
  /// into the thing being measured.
  final String purpose;

  final String executable;
  final List<String> arguments;

  /// What the same tool is called where Windows paths are used, when that
  /// differs. **Flutter ships `flutter.bat`** (CLAUDE.md §17), and a bare
  /// `flutter` is not found at all: Windows resolves PATHEXT only through a
  /// shell, which a probe does not use.
  final String? windowsExecutable;

  String executableFor(EnvironmentKind kind) =>
      usesWindowsPaths(kind) ? (windowsExecutable ?? executable) : executable;

  /// Whether this machine's kind rules the toolchain out on its own.
  ///
  /// **Only where the kind is enough to know.** Windows and WSL are not macOS,
  /// so Xcode cannot be there and no process needs spawning to find out. A
  /// `localPosix` may be a Mac or a Linux box and an `ssh` host is somebody
  /// else's machine, so both are asked rather than assumed.
  bool impossibleOn(EnvironmentKind kind) =>
      this == Toolchain.xcode &&
      (kind == EnvironmentKind.windowsNative || kind == EnvironmentKind.wsl);
}

/// What one machine answered about one toolchain.
class ToolchainReading {
  const ToolchainReading({
    required this.toolchain,
    required this.status,
    required this.readAt,
    this.version,
    this.detail,
  });

  /// Ruled out by the machine's kind, with no process spawned.
  ToolchainReading.impossible(this.toolchain, this.readAt)
    : status = ToolchainStatus.notApplicable,
      version = null,
      detail = null;

  final Toolchain toolchain;
  final ToolchainStatus status;
  final DateTime readAt;

  /// What it said it was, when it said anything. Never inferred.
  final String? version;

  /// Why it could not be used, in the machine's own words.
  final String? detail;
}

enum ToolchainStatus {
  /// Ran and named a version.
  present,

  /// Ran and would not say what it is. Usable, and honest about the gap.
  presentVersionUnknown,

  /// The machine answered, and it is not there.
  missing,

  /// The machine could not be asked at all — it was unreachable, or the ask
  /// itself failed. **Not the same as missing** (§19).
  unknown,

  /// This kind of machine cannot have it, established without asking.
  notApplicable,

  /// Found, and refused on purpose. The only case today is §17's: a POSIX
  /// environment whose `flutter` is really the Windows installation reached
  /// through a drive mount, which must not be run there at all.
  refused,
}

/// The first non-empty line, trimmed — which is where every one of these
/// tools puts its version, `java` on stderr included.
String? firstLineOf(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}
