import 'package:karmashala_flutter_apps/flutter_apps.dart';

/// Which of the server's command families a hosted run belongs to.
enum HostedRunFamily {
  /// `flutter run`, `pub get`, `analyze` or `test` (`flutter_run`).
  flutter,

  /// A project's build command (`project_build`).
  build;

  static HostedRunFamily? fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// The pane id every client opens a hosted run under.
const String kHostedRunPanePrefix = 'hosted-';

String hostedRunPaneId(String runId) => '$kHostedRunPanePrefix$runId';

/// The host session a pane named [paneId] attaches to — the terminal's own
/// `hostSessionIdFor(paneId:)` rule, so a pane opened under
/// [hostedRunPaneId] finds the session the server started (slice 3d).
String hostedRunSessionId(String paneId) =>
    'karmashala_local_$paneId'.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

/// A command the server runs as a session of its own for everybody to watch:
/// a Flutter run or gate, or a project's build. Any client attaches a pane to
/// [paneId]'s session; it keeps running with every client closed.
final class HostedRun {
  const HostedRun({
    required this.runId,
    required this.title,
    required this.family,
    required this.startedAt,
    this.endedAt,
    this.exitCode,
  });

  final String runId;
  final String title;
  final HostedRunFamily family;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// Null on a run still going, and on one that ended with no code.
  final int? exitCode;

  String get paneId => hostedRunPaneId(runId);

  String get hostSessionId => hostedRunSessionId(paneId);

  bool get isLive => endedAt == null;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'title': title,
    'family': family.name,
    'startedAt': startedAt.toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
    'exitCode': ?exitCode,
  };

  static HostedRun fromJson(Map<String, Object?> json) => HostedRun(
    runId: json['runId']! as String,
    title: json['title']! as String,
    family:
        HostedRunFamily.fromName(json['family']) ??
        (throw const FormatException('not a hosted run family')),
    startedAt: DateTime.parse(json['startedAt']! as String),
    endedAt: json['endedAt'] == null
        ? null
        : DateTime.parse(json['endedAt']! as String),
    exitCode: json['exitCode'] as int?,
  );

  bool sameAs(HostedRun other) =>
      runId == other.runId &&
      title == other.title &&
      family == other.family &&
      startedAt == other.startedAt &&
      endedAt == other.endedAt &&
      exitCode == other.exitCode;
}

/// One attached app, whole — the tool's `toJson` shows an agent less.
Map<String, Object?> attachedAppToJson(AttachedApp app) => {
  'id': app.id,
  'uri': app.uri.toString(),
  'discovery': app.discovery.name,
  'reachability': app.reachability.name,
  'observedAt': app.observedAt.toIso8601String(),
  'label': ?app.label,
  'sourcePath': ?app.sourcePath,
  'isolateId': ?app.isolateId,
  'detail': ?app.detail,
  'widgetLocations': app.widgetLocations.name,
  'reloadMethod': ?app.reloadMethod,
  'restartMethod': ?app.restartMethod,
};

AttachedApp attachedAppFromJson(Map<String, Object?> json) => AttachedApp(
  id: json['id']! as String,
  uri: Uri.parse(json['uri']! as String),
  discovery: _byName(AppDiscovery.values, json['discovery']),
  reachability: _byName(AppReachability.values, json['reachability']),
  observedAt: DateTime.parse(json['observedAt']! as String),
  label: json['label'] as String?,
  sourcePath: json['sourcePath'] as String?,
  isolateId: json['isolateId'] as String?,
  detail: json['detail'] as String?,
  widgetLocations: _byName(
    WidgetLocationSupport.values,
    json['widgetLocations'],
  ),
  reloadMethod: json['reloadMethod'] as String?,
  restartMethod: json['restartMethod'] as String?,
);

Map<String, Object?> flutterRegistryToJson(FlutterAppRegistry registry) => {
  'apps': [for (final app in registry.apps) attachedAppToJson(app)],
  if (registry.lookedAt != null)
    'lookedAt': registry.lookedAt!.toIso8601String(),
  'discoveryDirectory': ?registry.discoveryDirectory,
  'discoveryFailure': ?registry.discoveryFailure,
};

FlutterAppRegistry flutterRegistryFromJson(Map<String, Object?> json) =>
    FlutterAppRegistry(
      apps: [
        for (final app in json['apps']! as List)
          attachedAppFromJson((app as Map).cast<String, Object?>()),
      ],
      lookedAt: json['lookedAt'] == null
          ? null
          : DateTime.parse(json['lookedAt']! as String),
      discoveryDirectory: json['discoveryDirectory'] as String?,
      discoveryFailure: json['discoveryFailure'] as String?,
    );

FlutterSdkReading flutterSdkReadingFromJson(Map<String, Object?> json) {
  final refusal = json['refusal'];
  return FlutterSdkReading(
    environmentId: json['environmentId']! as String,
    readAt: DateTime.parse(json['readAt']! as String),
    executable: json['executable'] as String?,
    version: json['version'] as String?,
    refusal: refusal == null
        ? null
        : _byName(FlutterSdkRefusal.values, refusal),
    reason: json['reason'] as String? ?? '',
  );
}

/// One console line on the wire (`AppLogRecord.toJson`'s inverse).
AppLogRecord appLogRecordFromJson(Map<String, Object?> json) => AppLogRecord(
  source: _byName(AppLogSource.values, json['source']),
  at: DateTime.parse(json['at']! as String),
  message: json['message']! as String,
  loggerName: json['logger'] as String?,
  level: json['level'] as int?,
  detail: json['detail'] as String?,
  beforeAttach: json['beforeAttach'] == true,
);

T _byName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('"$name" is not one of ${values.first.runtimeType}');
}
