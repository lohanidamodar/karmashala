import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';

/// A Dart VM service that answers JSON-RPC in Dart, with no socket and no
/// running app: [client] is a real `VmService` and this is its far end.
///
/// Unhandled methods answer method-not-found, the way a profile-mode build
/// answers a call to an inspector extension that was compiled out.
class FakeVmService {
  FakeVmService({
    this.isolateId = 'isolates/1',
    this.isolateName = 'main',
    this.refuseStreams = const <String>{},
    this.selectedWidget,
  }) {
    client = VmService(
      _incoming.stream,
      _onMessage,
      disposeHandler: () async {
        await close();
      },
    );
  }

  final String isolateId;
  final String isolateName;

  /// Streams whose `streamListen` is refused, as an older VM service does.
  final Set<String> refuseStreams;

  /// What `getSelectedSummaryWidget` answers with, or null for "nothing is
  /// selected".
  final Map<String, Object?>? selectedWidget;

  late final VmService client;

  final StreamController<String> _incoming = StreamController<String>();

  /// Every request, in the order it was made.
  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  /// Extra or overriding handlers, by method name.
  final Map<String, Object? Function(Map<String, dynamic>)> handlers =
      <String, Object? Function(Map<String, dynamic>)>{};

  var _closed = false;

  List<String> get methods => requests.map((r) => r.method).toList();

  Map<String, dynamic>? paramsFor(String method) {
    for (final request in requests) {
      if (request.method == method) return request.params;
    }
    return null;
  }

  void _onMessage(String raw) {
    final message = jsonDecode(raw) as Map<String, dynamic>;
    final method = message['method'] as String;
    final params = (message['params'] as Map<String, dynamic>?) ?? {};
    requests.add((method: method, params: params));
    final id = message['id'];

    final override = handlers[method];
    final Object? result = override != null
        ? override(params)
        : _defaultResult(method, params);

    if (result is FakeRpcError) {
      _send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': result.code,
          'message': result.message,
        },
      });
      return;
    }
    _send(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  Object? _defaultResult(String method, Map<String, dynamic> params) =>
      switch (method) {
        'getVM' => <String, Object?>{
          'type': 'VM',
          'name': 'vm',
          'isolates': <Object?>[
            <String, Object?>{
              'type': '@Isolate',
              'id': isolateId,
              'name': isolateName,
              'number': '1',
              'isSystemIsolate': false,
            },
          ],
        },
        'streamListen' =>
          refuseStreams.contains(params['streamId'])
              ? const FakeRpcError(114, 'Stream not supported')
              : const <String, Object?>{'type': 'Success'},
        'ext.flutter.inspector.isWidgetCreationTracked' => <String, Object?>{
          'type': '_extensionType',
          'result': true,
        },
        'ext.flutter.inspector.show' => <String, Object?>{
          'type': '_extensionType',
          'enabled': params['enabled'],
        },
        'ext.flutter.inspector.getSelectedSummaryWidget' => <String, Object?>{
          'type': '_extensionType',
          'result': selectedWidget,
        },
        'ext.flutter.inspector.disposeGroup' => const <String, Object?>{
          'type': 'Success',
        },
        _ =>
          method.endsWith('.reloadSources') || method.endsWith('.hotRestart')
              ? const <String, Object?>{'type': 'Success'}
              : const FakeRpcError(-32601, 'Method not found'),
      };

  void _send(Map<String, Object?> message) {
    if (_closed || _incoming.isClosed) return;
    _incoming.add(jsonEncode(message));
  }

  /// Pushes one event on [streamId]; [event] needs a `kind`.
  void emit(String streamId, Map<String, Object?> event) =>
      _send(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'streamNotify',
        'params': <String, Object?>{
          'streamId': streamId,
          'event': <String, Object?>{'type': 'Event', ...event},
        },
      });

  void emitStdout(String text, {DateTime? at, bool stderr = false}) => emit(
    stderr ? EventStreams.kStderr : EventStreams.kStdout,
    <String, Object?>{
      'kind': EventKind.kWriteEvent,
      'timestamp': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'bytes': base64.encode(utf8.encode(text)),
    },
  );

  void emitDeveloperLog(
    String message, {
    String? loggerName,
    int level = 0,
    DateTime? at,
  }) => emit(EventStreams.kLogging, <String, Object?>{
    'kind': EventKind.kLogging,
    'timestamp': (at ?? DateTime.now()).millisecondsSinceEpoch,
    'logRecord': <String, Object?>{
      'type': 'LogRecord',
      'level': level,
      'sequenceNumber': 0,
      'time': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'message': _stringInstance(message),
      'loggerName': _stringInstance(loggerName ?? ''),
    },
  });

  void emitFlutterError(Map<String, Object?> tree, {DateTime? at}) =>
      emit(EventStreams.kExtension, <String, Object?>{
        'kind': EventKind.kExtension,
        'timestamp': (at ?? DateTime.now()).millisecondsSinceEpoch,
        'extensionKind': 'Flutter.Error',
        'extensionData': tree,
      });

  void emitFrame({DateTime? at}) =>
      emit(EventStreams.kExtension, <String, Object?>{
        'kind': EventKind.kExtension,
        'timestamp': (at ?? DateTime.now()).millisecondsSinceEpoch,
        'extensionKind': 'Flutter.Frame',
        'extensionData': const <String, Object?>{'number': 1, 'elapsed': 2000},
      });

  void emitServiceRegistered(String service, String method) =>
      emit(EventStreams.kService, <String, Object?>{
        'kind': EventKind.kServiceRegistered,
        'service': service,
        'method': method,
        'alias': 'Flutter Tools',
      });

  void emitServiceUnregistered(String service) =>
      emit(EventStreams.kService, <String, Object?>{
        'kind': EventKind.kServiceUnregistered,
        'service': service,
        'method': 's1.$service',
      });

  /// The framework's own selection push, as seen on Flutter 3.47.2.
  void emitNavigate({
    String fileUri = 'file:///C:/app/lib/main.dart',
    int line = 107,
    int column = 19,
  }) => emit('ToolEvent', <String, Object?>{
    'kind': EventKind.kExtension,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'extensionKind': 'navigate',
    'extensionData': <String, Object?>{
      'fileUri': fileUri,
      'line': line,
      'column': column,
      'source': 'flutter.inspector',
    },
  });

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  static Map<String, Object?> _stringInstance(String value) =>
      <String, Object?>{
        'type': '@Instance',
        'kind': 'String',
        'id': 'objects/${value.hashCode}',
        'valueAsString': value,
      };
}

/// What a VM service answers for a method it does not have. Returned rather
/// than thrown, so a test describes the far end's reply.
class FakeRpcError {
  const FakeRpcError(this.code, this.message);
  const FakeRpcError.methodNotFound()
    : code = -32601,
      message = 'Method not found';
  final int code;
  final String message;
}

/// One `Flutter.Error` payload: a summary node inside `properties`.
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
