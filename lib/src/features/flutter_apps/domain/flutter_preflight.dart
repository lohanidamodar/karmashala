/// What is in the way of a Flutter command, before anything is spawned.
///
/// Each value is a different thing to *do*, which is why they are not one
/// "not ready": an environment that cannot be named and an SDK that is not
/// installed need different people to fix them, and a project with no
/// `.dart_tool` needs nobody at all — the app can fix that one itself.
enum FlutterPreflightProblem {
  /// The resolver could not say where this checkout's commands run. Its own
  /// words are carried through (`environmentUnknown`, `sshUnavailable`, …).
  environmentUnresolved,

  /// No Flutter SDK in that environment, or one we refuse to run (§17).
  noSdk,

  /// The directory holds no `pubspec.yaml` with a `flutter:` key.
  notAFlutterProject,

  /// A package or a plugin: real Flutter, no entrypoint, nothing to run.
  notRunnable,

  /// No `.dart_tool/package_config.json`. `pub get` is the fix and the app can
  /// run it.
  noPackages,

  /// No device was named and none could be chosen.
  noDevice,

  /// Another session is driving that device. `DeviceClaims` writes the words.
  deviceBusy,

  /// A run for this project is already live.
  alreadyRunning,

  /// There is no terminal in this window, so nothing could be run where it
  /// would be visible.
  noPane,
}

/// The preflight line: one sentence naming the problem **and the fix**, or
/// nothing in the way.
///
/// A value rather than an exception, for the reason `EnvironmentResolution`
/// gives: the caller shows it. `flutter_run` puts it in the answer whether or
/// not it stopped anything, so an agent reading a successful reply still sees
/// what nearly went wrong.
class FlutterPreflight {
  const FlutterPreflight.clear() : problem = null, reason = '';

  const FlutterPreflight.blocked(
    FlutterPreflightProblem this.problem,
    this.reason,
  );

  final FlutterPreflightProblem? problem;

  /// Empty when clear. Names the fix, never only the fault.
  final String reason;

  bool get isClear => problem == null;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': isClear,
    if (problem != null) 'problem': problem!.name,
    if (reason.isNotEmpty) 'reason': reason,
  };

  @override
  String toString() => isClear ? 'preflight: clear' : 'preflight: $reason';
}
