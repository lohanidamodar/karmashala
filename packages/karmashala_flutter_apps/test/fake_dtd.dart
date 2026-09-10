import 'dart:async';
import 'dart:convert';

import 'package:karmashala_flutter_apps/flutter_apps.dart';

/// A Dart Tooling Daemon that answers in Dart: only `streamListen`,
/// `ConnectedApp.getVmServices` and the one event this app listens for.
class FakeDtd implements DtdChannel {
  FakeDtd({List<Map<String, Object?>> apps = const []}) : _apps = [...apps];

  final List<Map<String, Object?>> _apps;
  final _incoming = StreamController<String>.broadcast();

  /// Every method this daemon was asked for, in order.
  final List<String> calls = <String>[];

  var closed = false;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String message) {
    final request = jsonDecode(message) as Map<String, Object?>;
    final method = request['method'] as String;
    calls.add(method);
    final result = switch (method) {
      'ConnectedApp.getVmServices' => <String, Object?>{
        'type': 'VmServicesResponse',
        'vmServices': _apps,
      },
      _ => <String, Object?>{'type': 'Success'},
    };
    _incoming.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': result,
      }),
    );
  }

  /// An app registering after the first read, as an IDE's daemon does.
  void announce(String uri, {String? name}) {
    _apps.add(<String, Object?>{'uri': uri, 'name': ?name});
    _incoming.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'streamNotify',
        'params': <String, Object?>{
          'streamId': 'ConnectedApp',
          'eventKind': 'VmServiceRegistered',
          'eventData': <String, Object?>{'uri': uri, 'name': ?name},
        },
      }),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }
}
