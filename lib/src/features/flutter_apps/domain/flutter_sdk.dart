import 'package:agent_cli/process.dart';

/// How long a Flutter SDK reading is taken as still true.
///
/// The same twelve hours `kVersionReadingFreshFor` gives an agent CLI, for the
/// same reason and not by coincidence: a `flutter --version` is a whole tool
/// start, sessions here are long, and a number nobody is looking at is not
/// worth a process per launch. §20's durable half is the **age** beside the
/// reading, not the cadence that wrote it.
const Duration kFlutterSdkReadingFreshFor = Duration(hours: 12);

/// Why an environment has no Flutter we are willing to run.
///
/// Five values because they need five different things done about them, and
/// because collapsing [windowsInstallOnPosixPath] into "not found" is
/// precisely the silent failure CLAUDE.md §17 is about.
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

  /// The path **a person named** for this environment could not be run.
  ///
  /// Its own value rather than [notFound], because the thing to do about it is
  /// different and nothing else can be done at all: installing a Flutter will
  /// not help, and neither will PATH — the row says where to look and the
  /// answer is not there. Correct the row, or clear it and let PATH answer
  /// again. See `ExecutionEnvironment.flutterSdkPath`.
  handSetUnusable,
}

/// What `flutter` is called in [kind], and CLAUDE.md §17 written as code.
///
/// On Windows the name is `flutter.bat` and never `flutter`: the extensionless
/// file beside it is a **POSIX shell script**, and running it makes Flutter
/// decide it needs a Linux Dart SDK and swap one into the cache every terminal
/// on the machine shares. Naming the `.bat` is the whole of the fix, so it is
/// spelled once, here.
String flutterExecutableFor(EnvironmentKind kind) =>
    usesWindowsPaths(kind) ? 'flutter.bat' : 'flutter';

/// The refusal for a POSIX-environment `flutter` that is really the Windows
/// one, or null when the path is that environment's own.
///
/// `command -v flutter` inside a WSL distribution resolves to
/// `/mnt/c/Users/<you>/flutter/bin/flutter` whenever `/mnt/c` is on PATH,
/// which it is by default — and that file is the same POSIX script §17 forbids,
/// reached over DrvFs. It runs, it looks like it worked, and it replaces the
/// Windows `dart-sdk` with a Linux one for everybody. So a path under a drive
/// mount is **refused before anything is spawned**: the harm is in the
/// running, not in the looking.
///
/// [handSet] changes only where the sentence says the path came from, and it
/// exists because the other wording would be a small lie: a path somebody
/// typed into Settings is not "the only flutter on this distribution's PATH",
/// and telling them to install one inside the distribution is not the fix when
/// they have already named a file. The danger, and the refusal, are identical.
///
/// The judgement is the automount root, `/mnt/<letter>/`, which is what WSL
/// uses unless `/etc/wsl.conf` moves it. A distribution that has moved it hides
/// its Windows drives from this check and would be run — recorded here rather
/// than guessed at, because the alternative is spawning the thing to find out.
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

/// What one environment answered when it was asked where `flutter` is.
///
/// **A reading, not a setting.** It carries the moment it was taken, and it is
/// never a bare yes: an environment that could not be reached is not an
/// environment with no Flutter (§19), and a path we refuse to run is not a
/// path we failed to find.
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
