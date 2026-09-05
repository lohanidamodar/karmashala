import 'dart:convert';

import 'fake_command_runner.dart';

/// A `codex app-server` that exists only as JSON, over a [FakeProcessHandle].
///
/// It answers on the shape the real one was **measured** to use, which is what
/// makes it worth having rather than hand-waving: replies carry no `jsonrpc`
/// field, an unsolicited `remoteControl/status/changed` arrives right after
/// `initialize`, and an unknown method is answered with an error that has no
/// `id` at all. Each of those breaks a plausible client, and none of them is
/// guessable from the JSON-RPC specification.
class FakeCodexAppServer extends FakeProcessHandle {
  FakeCodexAppServer({this.codexHome = '/home/me/.codex', this.reply});

  /// What `initialize` reports as the store this server serves.
  final String codexHome;

  /// Answers one request that is not the handshake, or `null` to answer
  /// nothing at all. Omit it and every call is answered `{}`.
  final String? Function(
    FakeCodexAppServer server,
    int id,
    String method,
    Map<String, Object?> params,
  )?
  reply;

  /// Every request received, decoded, in order.
  final List<Map<String, Object?>> requests = [];

  List<String> get methods => [
    for (final request in requests) request['method']! as String,
  ];

  /// The params of the last `thread/name/set`, or `null` if there was none.
  Map<String, Object?>? get lastNameSet {
    for (final request in requests.reversed) {
      if (request['method'] == 'thread/name/set') {
        return (request['params'] as Map?)?.cast<String, Object?>();
      }
    }
    return null;
  }

  @override
  void writeLine(String line) {
    super.writeLine(line);
    final request = jsonDecode(line) as Map<String, Object?>;
    requests.add(request);
    final id = request['id'];
    if (id is! int) return;
    final method = request['method']! as String;
    if (method == 'initialize') {
      emitStdout(
        jsonEncode({
          'id': id,
          'result': {
            'userAgent': 'karmashala/0.0.0',
            'codexHome': codexHome,
            'platformFamily': 'unix',
            'platformOs': 'linux',
          },
        }),
      );
      emitStdout(
        jsonEncode({
          'method': 'remoteControl/status/changed',
          'params': {'status': 'disabled'},
        }),
      );
      return;
    }
    final scripted = reply;
    if (scripted == null) {
      emitStdout(jsonEncode({'id': id, 'result': <String, Object?>{}}));
      return;
    }
    final answer = scripted(
      this,
      id,
      method,
      (request['params'] as Map?)?.cast<String, Object?>() ?? const {},
    );
    if (answer != null) emitStdout(answer);
  }
}
