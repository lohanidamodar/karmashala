import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The Flutter apps the server runs and is attached to (slice 3d), asked
/// for: this app shows them and asks, the server does the work. Each request
/// is answered when done and refused in the server's words ([DataRefused]).
class FlutterData {
  FlutterData(this._client);

  final DataClient _client;

  Future<R> _ask<R>(FlutterWorkRequest<R> request) async =>
      (await _client.send(request)).value;

  /// The apps as the server last told them; empty until it has.
  FlutterAppRegistry get registry =>
      _client.flutterApps ?? const FlutterAppRegistry();

  /// Fires when the server's apps move.
  Stream<void> get changes =>
      _client.runsChanges.where((change) => change is FlutterAppsChanged);

  /// Has the server look again, and answers what it then holds.
  Future<FlutterAppRegistry> look() => _ask(const FlutterApps(look: true));

  Future<AttachedApp> attach(
    String vmServiceUri, {
    String? deviceSerial,
    String? label,
  }) => _ask(
    FlutterAttach(vmServiceUri, deviceSerial: deviceSerial, label: label),
  );

  Future<void> reload(String appId, {bool full = false}) =>
      _ask(FlutterReload(appId, full: full));

  Future<void> detach(String appId) => _ask(FlutterDetach(appId));

  Future<void> forget(String appId) => _ask(FlutterForget(appId));

  /// Waits for a tap in the app; answers the widget as an agent reads it.
  Future<String> pickWidget(String appId, {int timeoutSeconds = 120}) =>
      _ask(FlutterPickWidget(appId, timeoutSeconds: timeoutSeconds));

  Future<FlutterSdkReading> sdk(String environmentId, {bool force = false}) =>
      _ask(FlutterSdk(environmentId, force: force));

  /// [appId]'s console, its backlog first, then live.
  Stream<DataStreamItems> console(String appId) =>
      _client.openStream(kFlutterLogsStream, appId);
}

final flutterDataProvider = Provider<FlutterData>(
  (ref) => FlutterData(ref.watch(dataClientProvider)),
);
