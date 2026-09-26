import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_mcp/catalogue.dart';

import '../protocol/messages.dart';
import 'mcp_credentials.dart';
import 'tools/server_tools.dart';

/// What an agent is told when a tool needs the app and no app is connected.
const String kMcpAppNotRunning =
    'the Karmashala app is not running; this tool needs it';

/// A tool call that could not be run, or that the app reported failing. Its
/// text is exactly what the agent reads after `Error: `.
class McpToolRelayFailure implements Exception {
  const McpToolRelayFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Tool calls taken by the daemon: run here by [tools] — every tool that
/// needs no desktop UI (slice 2b) — or forwarded to the connected app, whose
/// tools (panes, the editor, browsers, devices, recordings) it sent last. No
/// call is timed out here — `session_wait` and `terminal_run` block for as
/// long as their own arguments say.
class McpToolRelay {
  McpToolRelay({this.cachePath, ServerTools? tools})
    : tools = tools ?? ServerTools() {
    _catalogue = _readCache();
  }

  /// The tools the server runs itself.
  final ServerTools tools;

  /// Where the catalogue is kept between runs, so agents still list tools when
  /// the daemon starts before the app. Null keeps it in memory only.
  final String? cachePath;

  late List<Map<String, Object?>> _catalogue;
  _AppLink? _app;
  final _pending = <int, _PendingCall>{};
  var _lastCallId = 0;

  /// What `tools/list` serves, annotated: the server's own tools, then the
  /// connected app's (else the last it sent) that the server does not run.
  List<Map<String, dynamic>> catalogue() => annotatedToolSchemas([
    ...tools.schemas,
    for (final tool in _catalogue)
      if (!tools.serves('${tool['name']}')) tool,
  ]);

  bool get appConnected => _app != null;

  /// [owner] runs tools from now on, with [tools] as its catalogue; frames to
  /// it go through [send].
  void adopt(
    Object owner,
    List<Map<String, Object?>> tools,
    void Function(HostMessage) send,
  ) {
    _app = _AppLink(owner, send);
    _catalogue = List.unmodifiable(tools);
    unawaited(_writeCache(tools));
  }

  /// [owner]'s answer to one call; ignored when nothing waits for it.
  void answer(Object owner, McpResultMessage result) {
    final pending = _pending[result.callId];
    if (pending == null || !identical(pending.owner, owner)) return;
    _pending.remove(result.callId);
    if (result.ok) {
      pending.done.complete(result.result);
    } else {
      pending.done.completeError(McpToolRelayFailure(result.error!));
    }
  }

  /// [owner] hung up: calls it was running fail, and nothing more goes to it.
  void detach(Object owner) {
    if (identical(_app?.owner, owner)) _app = null;
    for (final entry in _pending.entries.toList()) {
      if (!identical(entry.value.owner, owner)) continue;
      _pending.remove(entry.key);
      entry.value.done.completeError(
        const McpToolRelayFailure(
          'the Karmashala app closed before this tool finished',
        ),
      );
    }
  }

  /// Runs [tool] for [callerSessionId]: here when the server runs it, else in
  /// the app. Throws [McpToolRelayFailure] when the app is needed and none is
  /// connected, or its tool failed.
  Future<Object?> call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    final here = tools.call(tool, arguments, callerSessionId);
    if (here != null) return here;
    final app = _app;
    if (app == null) {
      return Future.error(const McpToolRelayFailure(kMcpAppNotRunning));
    }
    final callId = ++_lastCallId;
    final done = Completer<Object?>();
    _pending[callId] = _PendingCall(app.owner, done);
    app.send(
      McpCallMessage(
        callId: callId,
        tool: tool,
        arguments: arguments,
        callerSessionId: callerSessionId,
      ),
    );
    return done.future;
  }

  /// Fails every call in flight: the daemon is stopping.
  void close() {
    for (final pending in _pending.values) {
      pending.done.completeError(
        const McpToolRelayFailure('the session host is stopping'),
      );
    }
    _pending.clear();
    _app = null;
  }

  List<Map<String, Object?>> _readCache() {
    final path = cachePath;
    if (path == null) return const [];
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      if (json is! List) return const [];
      return List.unmodifiable(json.whereType<Map<String, Object?>>());
    } on Object {
      return const [];
    }
  }

  Future<void> _writeCache(List<Map<String, Object?>> tools) async {
    final path = cachePath;
    if (path == null) return;
    try {
      await writeOwnerOnly(path, jsonEncode(tools));
    } on Object {
      // Served from memory this run; only a daemon started without the app
      // would have listed them from here.
    }
  }
}

class _AppLink {
  _AppLink(this.owner, this.send);
  final Object owner;
  final void Function(HostMessage) send;
}

class _PendingCall {
  _PendingCall(this.owner, this.done);
  final Object owner;
  final Completer<Object?> done;
}
