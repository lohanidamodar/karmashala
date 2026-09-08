/// What the app asked Flutter to do.
enum FlutterCommandKind {
  pubGet,
  run,
  analyze,
  test;

  /// The argv after the SDK's own name.
  List<String> get arguments => switch (this) {
    FlutterCommandKind.pubGet => const <String>['pub', 'get'],
    FlutterCommandKind.run => const <String>['run'],
    FlutterCommandKind.analyze => const <String>['analyze'],
    FlutterCommandKind.test => const <String>['test'],
  };

  String get label => switch (this) {
    FlutterCommandKind.pubGet => 'pub get',
    FlutterCommandKind.run => 'run',
    FlutterCommandKind.analyze => 'analyze',
    FlutterCommandKind.test => 'test',
  };
}

/// Whether the process in a run's pane is still going — and the third answer.
///
/// `unknown` is not decoration: a pane whose id the terminal no longer knows
/// (the user closed the tab, the app restarted) is a run we have lost sight
/// of, and calling that "finished" would be the confident false statement §19
/// deletes. It is reported with the age of the last thing we did observe.
enum FlutterRunLiveness { running, finished, unknown }

/// One command the app started, and everything known about it.
///
/// **The pane is the process.** There is no second handle: a run's id *is* its
/// pane id, its liveness is the pane's liveness, and its output is the pane's
/// buffer. Nothing here polls anything — the liveness is read when someone
/// asks and carries [startedAt] so the answer has an age.
class FlutterCommandRun {
  const FlutterCommandRun({
    required this.paneId,
    required this.kind,
    required this.projectDirectory,
    required this.environmentId,
    required this.startedAt,
    required this.command,
    this.deviceId,
    this.vmServiceOutFile,
    this.vmServiceUri,
    this.appId,
    this.endedAt,
    this.exitCode,
  });

  /// The pane, and the run's identity. One run, one pane.
  final String paneId;

  final FlutterCommandKind kind;

  /// Where it runs, in that environment's own spelling.
  final String projectDirectory;

  final String environmentId;

  /// The argv actually spelled, so a reader can see the SDK that was chosen
  /// and the flags that were added.
  final List<String> command;

  final DateTime startedAt;

  /// The device a `flutter run` was pointed at, when it was pointed at one.
  final String? deviceId;

  /// Where `--vmservice-out-file` was pointed. Null for anything but a run.
  final String? vmServiceOutFile;

  /// The address the app announced, once it has. Null until then, which is
  /// "not yet" rather than "there is none".
  final String? vmServiceUri;

  /// The `flutter_apps` id this run's app is attached under, once it is.
  final String? appId;

  final DateTime? endedAt;

  /// Null while running **and** when the exit was never observed.
  final int? exitCode;

  bool get isAttached => appId != null;

  FlutterCommandRun copyWith({
    String? vmServiceUri,
    String? appId,
    DateTime? endedAt,
    int? exitCode,
  }) => FlutterCommandRun(
    paneId: paneId,
    kind: kind,
    projectDirectory: projectDirectory,
    environmentId: environmentId,
    startedAt: startedAt,
    command: command,
    deviceId: deviceId,
    vmServiceOutFile: vmServiceOutFile,
    vmServiceUri: vmServiceUri ?? this.vmServiceUri,
    appId: appId ?? this.appId,
    endedAt: endedAt ?? this.endedAt,
    exitCode: exitCode ?? this.exitCode,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'paneId': paneId,
    'kind': kind.name,
    'projectDirectory': projectDirectory,
    'environmentId': environmentId,
    'command': command,
    'startedAt': startedAt.toIso8601String(),
    if (deviceId != null) 'deviceId': deviceId,
    if (vmServiceUri != null) 'vmServiceUri': vmServiceUri,
    if (appId != null) 'appId': appId,
    if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
    if (exitCode != null) 'exitCode': exitCode,
  };
}
