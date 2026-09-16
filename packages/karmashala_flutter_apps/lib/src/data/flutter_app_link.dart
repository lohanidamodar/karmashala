import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart';

import '../domain/app_log_filter.dart';
import '../domain/app_log_record.dart';
import '../domain/attached_app.dart';
import '../domain/flutter_app_failure.dart';
import '../domain/flutter_error_summary.dart';
import '../domain/widget_selection.dart';
import 'vm_service_connector.dart';

/// The `ToolEvent` stream, which the generated `EventStreams` does not name;
/// the framework's `_notifyToolsOfSelection` is its only producer.
const String kToolEventStream = 'ToolEvent';

/// Service extension names as this SDK registers them: the selection read is
/// `getSelectedSummaryWidget`, not `getSelectedSummaryWidgetTree`.
const String kInspectorShow = 'ext.flutter.inspector.show';
const String kInspectorSelectedSummary =
    'ext.flutter.inspector.getSelectedSummaryWidget';
const String kInspectorCreationTracked =
    'ext.flutter.inspector.isWidgetCreationTracked';
const String kInspectorDisposeGroup = 'ext.flutter.inspector.disposeGroup';

/// The `flutter_tools`-registered services we use, by their *service* name.
const String kReloadSourcesService = 'reloadSources';
const String kHotRestartService = 'hotRestart';

/// One live connection to one running Flutter app: streams are subscribed once
/// at attach, and the app going away arrives as [done] completing, never a poll.
class FlutterAppLink {
  // Positional: a named parameter cannot be an initializing formal for a
  // private field.
  FlutterAppLink._(
    this._service,
    this.uri,
    this._logger,
    this._now, {
    required this.isolateId,
    required this.attachedAt,
    required this.toolEventStreamListenable,
  });

  final VmService _service;
  final Uri uri;

  /// The main isolate, which every service extension call is addressed to.
  final String isolateId;

  /// When the handshake finished. The boundary between the app's history and
  /// what is happening now — see [AppLogRecord.beforeAttach].
  final DateTime attachedAt;

  /// Whether this VM service accepted `streamListen` for `ToolEvent`; without
  /// it the widget picker must say so rather than wait for a `navigate` event
  /// that cannot arrive.
  final bool toolEventStreamListenable;

  final Logger _logger;
  final DateTime Function() _now;

  final AppLogBuffer _console = AppLogBuffer();
  final StreamController<AppLogRecord> _logs =
      StreamController<AppLogRecord>.broadcast();
  final StreamController<WidgetSourceLocation> _navigations =
      StreamController<WidgetSourceLocation>.broadcast();
  final StreamController<void> _servicesChanged =
      StreamController<void>.broadcast();
  final Completer<void> _done = Completer<void>();
  final List<StreamSubscription<Event>> _subscriptions =
      <StreamSubscription<Event>>[];

  /// Method name per registered service — `{'reloadSources':
  /// 's1.reloadSources'}` on this connection.
  final Map<String, String> _registered = <String, String>{};

  /// Second half of the history test: DDS replays its buffered events between
  /// `streamListen` and the reply to the next request.
  bool _handshakeDone = false;

  var _disposed = false;
  int _objectGroup = 0;

  /// Everything the app has said, oldest first, including what it said before
  /// we attached.
  List<AppLogRecord> get console => _console.records;

  /// Console lines discarded to stay inside the buffer. A count, not a time.
  int get droppedConsoleLines => _console.dropped;

  /// New console lines as they arrive.
  Stream<AppLogRecord> get logs => _logs.stream;

  /// Where the inspector says the selection now is. One event per selection
  /// change in the running app, pushed by the framework.
  Stream<WidgetSourceLocation> get navigations => _navigations.stream;

  /// Fires when a service registration appears or goes away — how "a Flutter
  /// tool is attached" stops being true while the app itself keeps running.
  Stream<void> get servicesChanged => _servicesChanged.stream;

  /// The newest [limit] console lines, oldest first.
  List<AppLogRecord> tail({int limit = 200, Set<AppLogSource>? sources}) =>
      _console.tail(limit: limit, sources: sources);

  /// Console lines ever received; the sequence number the next one will get.
  int get consoleAppended => _console.appended;

  /// The whole console under [query], kept current by [cache] — only lines
  /// numbered [hideBefore] and newer.
  AppLogFilterResult filterConsole(
    AppLogFilterCache cache,
    AppLogQuery query, {
    int hideBefore = 0,
  }) => cache.update(_console, query, hideBefore: hideBefore);

  /// Completes when the app closes the connection, or [dispose] is called.
  Future<void> get done => _done.future;

  String? get reloadMethod => _registered[kReloadSourcesService];
  String? get restartMethod => _registered[kHotRestartService];

  /// Opens a connection and finishes the handshake, or throws.
  ///
  /// Streams are subscribed *before* `getVM`: its reply ends the replayed
  /// history, and `postEvent` is a no-op while `Extension` has no listener.
  static Future<FlutterAppLink> attach(
    Uri wsUri, {
    VmServiceConnector connect = connectVmServiceOverWebSocket,
    DateTime Function() now = DateTime.now,
    Logger? logger,
  }) async {
    final log = logger ?? Logger('flutter_apps.link');
    final VmService service;
    try {
      service = await connect(wsUri);
    } on Object catch (error) {
      throw FlutterAppException(
        FlutterAppFailure.connectFailed,
        describeFlutterAppFailure(
          FlutterAppFailure.connectFailed,
          detail: '$error',
        ),
        cause: error,
      );
    }

    // Events that land before the link exists are held, not dropped: the
    // handshake is exactly when DDS flushes its replay buffer.
    void Function(String, Event)? sink;
    final held = <(String, Event)>[];
    var toolEvents = false;
    final subscriptions = <StreamSubscription<Event>>[];
    for (final stream in const <String>[
      EventStreams.kStdout,
      EventStreams.kStderr,
      EventStreams.kLogging,
      EventStreams.kExtension,
      EventStreams.kService,
      kToolEventStream,
    ]) {
      subscriptions.add(
        service.onEvent(stream).listen((event) {
          final handler = sink;
          if (handler == null) {
            held.add((stream, event));
          } else {
            handler(stream, event);
          }
        }),
      );
      final listening = await _listen(service, stream, log);
      if (stream == kToolEventStream) toolEvents = listening;
    }

    final VM vm;
    try {
      vm = await service.getVM();
    } on Object catch (error) {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await service.dispose();
      throw FlutterAppException(
        FlutterAppFailure.connectFailed,
        describeFlutterAppFailure(
          FlutterAppFailure.connectFailed,
          detail: '$error',
        ),
        cause: error,
      );
    }

    final isolates = vm.isolates ?? const <IsolateRef>[];
    final main = isolates.firstWhere(
      (isolate) => (isolate.name ?? '').contains('main'),
      orElse: () => isolates.isEmpty ? IsolateRef() : isolates.first,
    );
    final isolateId = main.id;
    if (isolateId == null) {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await service.dispose();
      throw FlutterAppException(
        FlutterAppFailure.connectFailed,
        describeFlutterAppFailure(
          FlutterAppFailure.connectFailed,
          detail: 'the VM reported no isolate to talk to',
        ),
      );
    }

    final link = FlutterAppLink._(
      service,
      wsUri,
      log,
      now,
      isolateId: isolateId,
      attachedAt: now(),
      toolEventStreamListenable: toolEvents,
    );
    link._subscriptions.addAll(subscriptions);
    // Everything that landed during the handshake is history by construction.
    for (final event in held) {
      link._onEvent(event.$1, event.$2);
    }
    link._handshakeDone = true;
    sink = link._onEvent;
    unawaited(
      service.onDone.then((_) {
        link._note('The app closed its VM service connection.');
        link._finish();
      }),
    );
    link._note('Attached to ${wsUri.host}:${wsUri.port}.');
    return link;
  }

  static Future<bool> _listen(
    VmService service,
    String stream,
    Logger log,
  ) async {
    try {
      await service.streamListen(stream);
      return true;
    } on RPCError catch (error) {
      // 103 is "stream already subscribed", a success here; anything else means
      // this VM service lacks the stream, and is reported rather than retried.
      if (error.code == 103) return true;
      log.fine('streamListen $stream refused: ${error.message}');
      return false;
    }
  }

  void _onEvent(String stream, Event event) {
    if (_disposed) return;
    switch (stream) {
      case EventStreams.kStdout:
      case EventStreams.kStderr:
        _onWrite(event, stream == EventStreams.kStderr);
      case EventStreams.kLogging:
        _onLogRecord(event);
      case EventStreams.kExtension:
        _onExtension(event);
      case EventStreams.kService:
        _onService(event);
      case kToolEventStream:
        _onToolEvent(event);
    }
  }

  void _onWrite(Event event, bool isError) {
    final encoded = event.bytes;
    if (encoded == null) return;
    final String text;
    try {
      text = utf8.decode(base64.decode(encoded), allowMalformed: true);
    } on FormatException {
      return;
    }
    if (text.trim().isEmpty) return;
    _emit(
      AppLogRecord(
        source: isError ? AppLogSource.stderr : AppLogSource.stdout,
        at: _stampOf(event),
        message: text.trimRight(),
        beforeAttach: _isHistory(event),
      ),
    );
  }

  void _onLogRecord(Event event) {
    final record = event.logRecord;
    if (record == null) return;
    _emit(
      AppLogRecord(
        source: AppLogSource.developerLog,
        at: _stampOf(event),
        message: _instanceText(record.message) ?? '',
        loggerName: _instanceText(record.loggerName),
        level: record.level,
        detail: _instanceText(record.stackTrace),
        beforeAttach: _isHistory(event),
      ),
    );
  }

  void _onExtension(Event event) {
    // `Flutter.Frame` arrives here several times a second and there is no
    // server-side filter for extension kind, so the rest is dropped here.
    if (event.extensionKind != 'Flutter.Error') return;
    final data = event.extensionData?.data;
    if (data == null) return;
    _emit(
      summariseFlutterError(
        data,
        at: _stampOf(event),
        beforeAttach: _isHistory(event),
      ),
    );
  }

  void _onService(Event event) {
    final service = event.service;
    if (service == null) return;
    if (event.kind == EventKind.kServiceUnregistered) {
      _registered.remove(service);
      if (service == kReloadSourcesService) {
        _note('The Flutter tool detached; hot reload is no longer available.');
      }
      if (!_servicesChanged.isClosed) _servicesChanged.add(null);
      return;
    }
    final method = event.method;
    if (method == null) return;
    _registered[service] = method;
    if (!_servicesChanged.isClosed) _servicesChanged.add(null);
  }

  void _onToolEvent(Event event) {
    if (event.extensionKind != 'navigate') return;
    final data = event.extensionData?.data;
    if (data == null) return;
    final location = WidgetSourceLocation.fromNavigateEvent(data);
    if (location == null) return;
    if (!_navigations.isClosed) _navigations.add(location);
  }

  /// The event's own clock where it has one, ours rather than zero when not.
  DateTime _stampOf(Event event) {
    final timestamp = event.timestamp;
    return timestamp == null
        ? _now()
        : DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  /// Whether an event happened before we attached. The handshake test is exact;
  /// the timestamp test covers a later replay and only ever *adds* history,
  /// because a device's clock across an `adb forward` is not ours to trust.
  bool _isHistory(Event event) {
    if (!_handshakeDone) return true;
    final timestamp = event.timestamp;
    if (timestamp == null) return false;
    return DateTime.fromMillisecondsSinceEpoch(timestamp).isBefore(attachedAt);
  }

  void _note(String message) => _emit(
    AppLogRecord(source: AppLogSource.lifecycle, at: _now(), message: message),
  );

  void _emit(AppLogRecord record) {
    _console.add(record);
    if (!_logs.isClosed) _logs.add(record);
  }

  static String? _instanceText(InstanceRef? ref) {
    if (ref == null) return null;
    final text = ref.valueAsString;
    if (text == null || text.isEmpty) return null;
    return text;
  }

  /// Asks the Flutter tool that owns this process to recompile and reload.
  ///
  /// Not a VM service RPC: `reloadSources` is a service `flutter_tools`
  /// registers, and its method name is read off `ServiceRegistered`, not
  /// assumed.
  Future<void> hotReload() async {
    final method = reloadMethod;
    if (method == null) {
      throw FlutterAppException(
        FlutterAppFailure.notToolDriven,
        describeFlutterAppFailure(FlutterAppFailure.notToolDriven),
      );
    }
    await _call(method, <String, dynamic>{
      'isolateId': isolateId,
      'force': false,
      'pause': false,
    });
  }

  /// Restarts the app in place, re-running `main()`.
  Future<void> hotRestart() async {
    final method = restartMethod;
    if (method == null) {
      throw FlutterAppException(
        FlutterAppFailure.notToolDriven,
        describeFlutterAppFailure(FlutterAppFailure.notToolDriven),
      );
    }
    await _call(method, <String, dynamic>{'pause': false});
  }

  /// Whether this build carries `creationLocation` for its widgets.
  Future<WidgetLocationSupport> widgetLocationSupport() async {
    try {
      final reply = await _service.callServiceExtension(
        kInspectorCreationTracked,
        isolateId: isolateId,
      );
      return reply.json?['result'] == true
          ? WidgetLocationSupport.tracked
          : WidgetLocationSupport.absent;
    } on Object catch (error) {
      _logger.fine('isWidgetCreationTracked did not answer: $error');
      return WidgetLocationSupport.unknown;
    }
  }

  /// Turns the running app's own widget-select mode on or off. The value is a
  /// *string*: `_registerBoolServiceExtension` compares `enabled == 'true'`.
  Future<void> setWidgetSelectMode({required bool enabled}) =>
      _call(kInspectorShow, <String, dynamic>{
        'isolateId': isolateId,
        'enabled': enabled ? 'true' : 'false',
      });

  /// Reads whatever the inspector has selected right now, or `null` when
  /// nothing is — select mode can be on with no tap yet.
  Future<WidgetSelection?> selectedWidget() async {
    final group = 'karmashala-${_objectGroup++}';
    try {
      final reply = await _service.callServiceExtension(
        kInspectorSelectedSummary,
        isolateId: isolateId,
        args: <String, dynamic>{'objectGroup': group},
      );
      return WidgetSelection.fromInspectorNode(reply.json?['result']);
    } finally {
      // The inspector pins every object it hands out until its group is
      // disposed, so a pick that skipped this would leak an element tree.
      try {
        await _service.callServiceExtension(
          kInspectorDisposeGroup,
          isolateId: isolateId,
          args: <String, dynamic>{'objectGroup': group},
        );
      } on Object catch (error) {
        _logger.fine('disposeGroup($group) failed: $error');
      }
    }
  }

  Future<Response> _call(String method, Map<String, dynamic> args) async {
    try {
      return await _service.callServiceExtension(method, args: args);
    } on RPCError catch (error) {
      throw FlutterAppException(
        error.code == RPCErrorKind.kMethodNotFound.code
            ? FlutterAppFailure.extensionMissing
            : FlutterAppFailure.malformedResponse,
        describeFlutterAppFailure(
          error.code == RPCErrorKind.kMethodNotFound.code
              ? FlutterAppFailure.extensionMissing
              : FlutterAppFailure.malformedResponse,
          detail: '$method: ${error.message}',
        ),
        cause: error,
      );
    } on Object catch (error) {
      throw FlutterAppException(
        FlutterAppFailure.disconnected,
        describeFlutterAppFailure(
          FlutterAppFailure.disconnected,
          detail: '$method: $error',
        ),
        cause: error,
      );
    }
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Closes the connection and everything hanging off it. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _logs.close();
    await _navigations.close();
    await _servicesChanged.close();
    _finish();
    try {
      await _service.dispose();
    } on Object catch (error) {
      _logger.fine('VM service dispose: $error');
    }
  }
}
