import 'package:agent_cli/process.dart';

/// How long a Flutter SDK reading is taken as still true — the same twelve
/// hours `kVersionReadingFreshFor` gives an agent CLI, for the same reason.
const Duration kFlutterSdkReadingFreshFor = Duration(hours: 12);

/// Why an environment has no Flutter we are willing to run. Collapsing
/// [windowsInstallOnPosixPath] into "not found" is the §17 silent failure.
enum FlutterSdkRefusal {
  /// Nothing named `flutter` on that environment's PATH.
  notFound,

  /// The environment itself could not be reached, so the absence proves
  /// nothing — a stopped distribution answers `command -v` exactly like one
  /// with no Flutter in it.
  environmentUnreachable,

  /// A POSIX environment's `flutter` **is the Windows installation**, reached
  /// through a drive mount. Running it is the §17 disaster.
  windowsInstallOnPosixPath,

  /// It was located and would not say what version it is.
  versionUnreadable,

  /// The path **a person named** could not be run. Its own value rather than
  /// [notFound]: only correcting or clearing the row helps.
  handSetUnusable,
}

/// What `flutter` is called in [kind] — `flutter.bat` on Windows, never the
/// extensionless POSIX script beside it (CLAUDE.md §17).
String flutterExecutableFor(EnvironmentKind kind) =>
    usesWindowsPaths(kind) ? 'flutter.bat' : 'flutter';

/// The refusal for a POSIX-environment `flutter` that is really the Windows one
/// (CLAUDE.md §17), or null when the path is that environment's own.
///
/// The test is the `/mnt/<letter>/` automount root, so a distribution that has
/// moved it in `/etc/wsl.conf` hides its drives here and would be run.
String? windowsInstallRefusal(
  EnvironmentKind kind,
  String path, {
  bool handSet = false,
}) {
  if (kind != EnvironmentKind.wsl) return null;
  if (!RegExp(r'^/mnt/[a-zA-Z]/').hasMatch(path)) return null;
  final source = handSet
      ? 'The Flutter SDK path set for this distribution is $path'
      : 'The only "flutter" on this distribution\'s PATH is $path';
  final fix = handSet
      ? 'Point it at a Flutter installed inside the distribution, clear it to '
            'look on PATH, or run this checkout in the Windows environment '
            'instead.'
      : 'Install Flutter inside the distribution, or run this checkout in the '
            'Windows environment instead.';
  return '$source — the Windows installation, reached through the drive '
      'mount. Running it makes Flutter download a Linux Dart SDK over the '
      'Windows one that every terminal, build and agent on this machine '
      'shares, and it fails silently for whoever ran it (CLAUDE.md §17). $fix';
}

/// What one environment answered when asked where `flutter` is — a reading,
/// not a setting: unreachable is not "no Flutter", refused is not "not found".
class FlutterSdkReading {
  const FlutterSdkReading({
    required this.environmentId,
    required this.readAt,
    this.executable,
    this.version,
    this.refusal,
    this.reason = '',
  });

  /// The refusal that needs no process at all.
  const FlutterSdkReading.refused({
    required this.environmentId,
    required this.readAt,
    required FlutterSdkRefusal this.refusal,
    required this.reason,
  }) : executable = null,
       version = null;

  final String environmentId;

  /// When this was measured. Rendered with `describeAge` wherever it is shown.
  final DateTime readAt;

  /// The path to run, as spelled in that environment. Null on a refusal.
  final String? executable;

  /// What `flutter --version` said, when it was asked and answered.
  final String? version;

  final FlutterSdkRefusal? refusal;

  /// One sentence naming the problem *and* the fix. Empty when usable.
  final String reason;

  /// Whether a command may be spelled with this.
  bool get isUsable => executable != null && refusal == null;

  /// Whether [readAt] is recent enough to reuse without asking again.
  bool isFreshAt(DateTime now, {Duration freshFor = kFlutterSdkReadingFreshFor}) =>
      now.difference(readAt) < freshFor;

  FlutterSdkReading copyWith({String? version, DateTime? readAt}) =>
      FlutterSdkReading(
        environmentId: environmentId,
        readAt: readAt ?? this.readAt,
        executable: executable,
        version: version ?? this.version,
        refusal: refusal,
        reason: reason,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'environmentId': environmentId,
    'readAt': readAt.toIso8601String(),
    if (executable != null) 'executable': executable,
    if (version != null) 'version': version,
    if (refusal != null) 'refusal': refusal!.name,
    if (reason.isNotEmpty) 'reason': reason,
  };
}
