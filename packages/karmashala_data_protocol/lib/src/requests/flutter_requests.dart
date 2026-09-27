part of '../data_request.dart';

// Flutter apps, run by the server (slice 3d). The server keeps the attached
// apps — found through its runs' `--vmservice-out-file`, the tooling daemons
// on its machine, or an address handed to it — and drives them; a client
// shows them (`FlutterAppsChanged`) and asks. A console is followed on a data
// stream (`kFlutterLogsStream`), never polled. Every one waits on a VM
// service or a process, so every one is answered when done.

DataRequest<Object?>? _flutterRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      FlutterApps.name => FlutterApps(
        look: args.boolean('look', orElse: false),
      ),
      FlutterAttach.name => FlutterAttach(
        args.string('vmServiceUri'),
        deviceSerial: args.optionalString('deviceSerial'),
        label: args.optionalString('label'),
      ),
      FlutterReload.name => FlutterReload(
        args.string('appId'),
        full: args.boolean('full', orElse: false),
      ),
      FlutterDetach.name => FlutterDetach(args.string('appId')),
      FlutterForget.name => FlutterForget(args.string('appId')),
      FlutterPickWidget.name => FlutterPickWidget(
        args.string('appId'),
        timeoutSeconds: args.optionalInt('timeoutSeconds') ?? 120,
      ),
      FlutterSdk.name => FlutterSdk(
        args.string('environmentId'),
        force: args.boolean('force', orElse: false),
      ),
      _ => null,
    };

/// Work the server does with the Flutter apps on its machine.
sealed class FlutterWorkRequest<R> extends DataRequest<R> {
  const FlutterWorkRequest();
}

/// The apps the server knows, after looking again when [look].
final class FlutterApps extends FlutterWorkRequest<FlutterAppRegistry> {
  const FlutterApps({this.look = false});

  static const String name = 'flutter.apps';

  final bool look;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'look': look};

  @override
  Object? resultToJson(FlutterAppRegistry result) =>
      flutterRegistryToJson(result);

  @override
  FlutterAppRegistry resultFromJson(Object? json) =>
      _decode(kind, () => flutterRegistryFromJson(_object(json, kind)));
}

/// Attaches the server to [vmServiceUri]. [deviceSerial] says a device's log
/// announced it (the client forwarded the port); [label] names it.
final class FlutterAttach extends FlutterWorkRequest<AttachedApp> {
  const FlutterAttach(this.vmServiceUri, {this.deviceSerial, this.label});

  static const String name = 'flutter.attach';

  final String vmServiceUri;
  final String? deviceSerial;
  final String? label;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'vmServiceUri': vmServiceUri,
    'deviceSerial': ?deviceSerial,
    'label': ?label,
  };

  @override
  Object? resultToJson(AttachedApp result) => attachedAppToJson(result);

  @override
  AttachedApp resultFromJson(Object? json) =>
      _decode(kind, () => attachedAppFromJson(_object(json, kind)));
}

/// Hot reload (hot restart when [full]) app [appId].
final class FlutterReload extends FlutterWorkRequest<DataAck> {
  const FlutterReload(this.appId, {this.full = false});

  static const String name = 'flutter.reload';

  final String appId;
  final bool full;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'appId': appId, 'full': full};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Closes the server's connection to [appId], leaving the app running.
final class FlutterDetach extends FlutterWorkRequest<DataAck> {
  const FlutterDetach(this.appId);

  static const String name = 'flutter.detach';

  final String appId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'appId': appId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Drops [appId]'s row — and its address file, when nothing answers on it.
final class FlutterForget extends FlutterWorkRequest<DataAck> {
  const FlutterForget(this.appId);

  static const String name = 'flutter.forget';

  final String appId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'appId': appId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Puts [appId] in widget-select mode and waits (up to [timeoutSeconds]) for
/// a tap; answers the picked widget as the sentence an agent reads.
final class FlutterPickWidget extends FlutterWorkRequest<String> {
  const FlutterPickWidget(this.appId, {this.timeoutSeconds = 120});

  static const String name = 'flutter.pickWidget';

  final String appId;
  final int timeoutSeconds;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'appId': appId,
    'timeoutSeconds': timeoutSeconds,
  };

  @override
  Object? resultToJson(String result) => result;

  @override
  String resultFromJson(Object? json) =>
      json is String ? json : _badAnswer(kind);
}

/// Where `flutter` is in environment [environmentId], read again when
/// [force] or when the last reading is stale. A hand-set path comes from the
/// `settings.v1` preference.
final class FlutterSdk extends FlutterWorkRequest<FlutterSdkReading> {
  const FlutterSdk(this.environmentId, {this.force = false});

  static const String name = 'flutter.sdk';

  final String environmentId;
  final bool force;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environmentId': environmentId,
    'force': force,
  };

  @override
  Object? resultToJson(FlutterSdkReading result) => result.toJson();

  @override
  FlutterSdkReading resultFromJson(Object? json) =>
      _decode(kind, () => flutterSdkReadingFromJson(_object(json, kind)));
}
