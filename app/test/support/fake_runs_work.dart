part of 'fake_data_server.dart';

/// The server's Flutter apps, hosted runs and browser (slice 3d) as a test
/// scripts it: what the server holds, what each request answers, and the
/// console lines it streams. Nothing is attached, launched or driven.
class FakeRunsWork {
  FakeRunsWork._(this._server);

  final FakeDataServer _server;

  /// The apps the server holds; [setApps] tells every window.
  var apps = const FlutterAppRegistry();

  /// The browser as the server holds it; [setBrowser] tells every window.
  var browser = const BrowserState();

  /// Every Flutter and browser request asked, in order.
  final asked = <DataRequest<Object?>>[];

  /// Answers a Flutter request in place of the defaults; throw a
  /// [DataRefused] to refuse it.
  Object? Function(FlutterWorkRequest<Object?> request)? onFlutter;

  /// Answers a browser request in place of the defaults.
  Object? Function(BrowserWorkRequest<Object?> request)? onBrowser;

  final _consoles = <String, StreamController<DataStreamItems>>{};
  var _streamIds = 0;

  void setApps(FlutterAppRegistry registry) {
    apps = registry;
    _server._tell(null, [FlutterAppsChanged(registry)]);
  }

  void setBrowser(BrowserState state) {
    browser = state;
    _server._tell(null, [BrowserStateChanged(state)]);
  }

  /// A run the server started (or ended), told to every window.
  void run(HostedRun run) => _server._tell(null, [HostedRunChanged(run)]);

  /// Who drives which device on the server's machine (slice 4a), told to
  /// every window.
  void holds(List<DeviceHold> holds) =>
      _server._tell(null, [DeviceClaimsChanged(holds)]);

  /// Streams [records] on app [appId]'s console, as one batch; [dropped]
  /// counts what the server did not send. Kept, so a window that opens the
  /// console later gets them first, as the server's ring gives them.
  void log(String appId, List<AppLogRecord> records, {int dropped = 0}) {
    (_logged[appId] ??= []).addAll(records);
    _consoles[appId]?.add(
      DataStreamItems(0, [
        for (final record in records) record.toJson(),
      ], dropped: dropped),
    );
  }

  /// Every line app [appId] said, as the server holds them.
  List<AppLogRecord> logged(String appId) => _logged[appId] ?? const [];
  final _logged = <String, List<AppLogRecord>>{};

  /// Whether a window follows app [appId]'s console now.
  bool following(String appId) => _consoles.containsKey(appId);

  Stream<DataStreamItems> _open(String source, String key) {
    late final StreamController<DataStreamItems> controller;
    final id = ++_streamIds;
    controller = StreamController<DataStreamItems>(
      onListen: () {
        if (source != kFlutterLogsStream) {
          controller
            ..add(DataStreamItems(id, const [], ended: 'no such stream'))
            ..close();
          return;
        }
        _consoles[key] = controller;
        final backlog = logged(key);
        if (backlog.isNotEmpty) {
          controller.add(
            DataStreamItems(id, [
              for (final record in backlog) record.toJson(),
            ]),
          );
        }
      },
      onCancel: () => _consoles.remove(key),
    );
    return controller.stream;
  }

  Object? _flutter(FlutterWorkRequest<Object?> request) {
    asked.add(request);
    final scripted = onFlutter;
    if (scripted != null) return scripted(request);
    return switch (request) {
      FlutterApps() => apps,
      FlutterAttach(:final vmServiceUri) => throw DataRefused(
        DataRefusalCode.failed,
        'Nothing answered on $vmServiceUri.',
      ),
      FlutterReload() || FlutterDetach() || FlutterForget() => const DataAck(),
      FlutterPickWidget() => 'Widget: Text. Written at lib/main.dart:1:1.',
      FlutterSdk(:final environmentId) => FlutterSdkReading(
        environmentId: environmentId,
        readAt: DateTime.utc(2026, 9, 27),
        executable: 'flutter',
        version: '3.41.0',
      ),
    };
  }

  Object? _browser(BrowserWorkRequest<Object?> request) {
    asked.add(request);
    final scripted = onBrowser;
    if (scripted != null) return scripted(request);
    return switch (request) {
      BrowserStateRequest() => browser,
      BrowserScreenshot() => Uint8List(0),
      BrowserPickElement() => throw const DataRefused(
        DataRefusalCode.failed,
        'Nothing was picked.',
      ),
      BrowserCancelPick() => const DataAck(),
      BrowserEvaluate() || BrowserFind() => '',
    };
  }
}
