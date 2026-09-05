import 'dart:convert';

import 'fake_command_runner.dart';

/// A `codex app-server` that exists only as JSON, over a [FakeProcessHandle].
///
/// It answers on the shape the real one was **measured** to use, which is what
/// makes it worth having rather than hand-waving: replies carry no `jsonrpc`
/// field, an unsolicited `remoteControl/status/changed` arrives right after
/// `initialize`, and an error reply puts its `id` *last*, after a message that
/// runs to 3.7 KB. Each of those breaks a plausible client, and none of them is
/// guessable from the JSON-RPC specification.
class FakeCodexAppServer extends FakeProcessHandle {
  FakeCodexAppServer({this.codexHome = '/home/me/.codex', this.reply});

  /// A server whose `thread/list` answers out of [rows], [pageSize] at a time.
  ///
  /// The cursor is the index of the next row — enough to page deterministically
  /// — and `nextCursor` is null on the last page, which is how the real server
  /// says it is exhausted.
  factory FakeCodexAppServer.withThreads(
    List<Map<String, Object?>> rows, {
    String codexHome = '/home/me/.codex',
    int pageSize = 100,
  }) => FakeCodexAppServer(
    codexHome: codexHome,
    reply: (server, id, method, params) {
      if (method != 'thread/list') {
        return jsonEncode({'id': id, 'result': <String, Object?>{}});
      }
      final from = int.tryParse('${params['cursor'] ?? 0}') ?? 0;
      final to = (from + pageSize).clamp(0, rows.length);
      return jsonEncode({
        'id': id,
        'result': {
          'data': rows.sublist(from.clamp(0, rows.length), to),
          'nextCursor': to < rows.length ? '$to' : null,
          'backwardsCursor': null,
        },
      });
    },
  );

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

  /// The params of every `thread/list`, in order.
  List<Map<String, Object?>> get threadListParams => [
    for (final request in requests)
      if (request['method'] == 'thread/list')
        (request['params'] as Map?)?.cast<String, Object?>() ?? const {},
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
