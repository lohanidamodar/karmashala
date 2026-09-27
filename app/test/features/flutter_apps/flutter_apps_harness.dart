import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';

/// When the server attached, in these tests; a line stamped earlier is
/// history the VM service replayed.
final kAttachedAt = DateTime.utc(2026, 9, 8);

AttachedApp attachedApp({
  String id = '127.0.0.1:1/a=',
  String label = 'windows',
  AppDiscovery discovery = AppDiscovery.uriFile,
  AppReachability reachability = AppReachability.attached,
  String? reloadMethod,
  WidgetLocationSupport widgetLocations = WidgetLocationSupport.unknown,
  String? detail,
}) => AttachedApp(
  id: id,
  uri: Uri.parse('ws://$id/ws'),
  discovery: discovery,
  reachability: reachability,
  observedAt: kAttachedAt,
  label: label,
  widgetLocations: widgetLocations,
  reloadMethod: reloadMethod,
  detail: detail,
);

/// The registry the server holds with [apps] in it, looked at just now.
FlutterAppRegistry registryOf(List<AttachedApp> apps) =>
    FlutterAppRegistry(apps: apps, lookedAt: kAttachedAt);

/// A container over a fake server holding [apps], with no adb and no devices
/// — opening the pane spawns nothing and reads no real phone.
Future<(ProviderContainer, FakeDataServer)> flutterPaneContainer({
  List<AttachedApp>? apps,
}) async {
  final server = FakeDataServer();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FixedClock(kAttachedAt)),
      adbServiceProvider.overrideWithValue(null),
      devicesProvider.overrideWith((ref) async => const []),
      await server.override(),
    ],
  );
  final registry = registryOf(apps ?? [attachedApp()]);
  server.runs.apps = registry;
  server.runs.setApps(registry);
  return (container, server);
}

/// What an app says, streamed by the fake server as the real one streams a
/// `FlutterAppLink`'s console.
class ConsoleFake {
  ConsoleFake(this.server, {this.appId = '127.0.0.1:1/a='});

  final FakeDataServer server;
  final String appId;

  void emitStdout(String text, {bool stderr = false, DateTime? at}) {
    final stamp = at ?? kAttachedAt;
    server.runs.log(appId, [
      for (final line in text.split('\n'))
        if (line.isNotEmpty)
          AppLogRecord(
            source: stderr ? AppLogSource.stderr : AppLogSource.stdout,
            at: stamp,
            message: line,
            beforeAttach: stamp.isBefore(kAttachedAt),
          ),
    ]);
  }

  void emitDeveloperLog(String message, {String? loggerName}) =>
      server.runs.log(appId, [
        AppLogRecord(
          source: AppLogSource.developerLog,
          at: kAttachedAt,
          message: message,
          loggerName: loggerName,
        ),
      ]);

  void emitFlutterError(Map<String, Object?> tree) =>
      server.runs.log(appId, [summariseFlutterError(tree, at: kAttachedAt)]);
}

/// One `Flutter.Error` payload, shaped the way the framework serialises a
/// `FlutterErrorDetails` tree.
Map<String, Object?> flutterErrorTree({
  String category = 'Exception caught by widgets library',
  String summary = 'The following StateError was thrown building Boom:',
  List<String> body = const <String>['Bad state: broken'],
}) => <String, Object?>{
  'description': category,
  'type': '_FlutterErrorDetailsNode',
  'properties': <Object?>[
    <String, Object?>{
      'description': summary,
      'type': 'ErrorSummary',
      'level': 'summary',
      'showName': false,
    },
    for (final line in body)
      <String, Object?>{
        'description': line,
        'type': 'ErrorDescription',
        'showName': false,
      },
  ],
};
