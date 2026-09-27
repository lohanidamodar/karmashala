/// One family of agent tools the server runs itself (slice 2b): the schemas
/// it serves and the calls it answers. A call it answers `null` for is handed
/// to the connected app — a session that runs in one of the app's own panes,
/// a browser or device run — and refused in words with no app.
library;

import 'dart:async';

/// A family of agent tools the server runs. Failures are thrown, as the app's
/// tools threw them — `ArgumentError` for a caller's mistake, `StateError`
/// for the world not being as asked — and reach the agent as `Error: <text>`,
/// exactly as they did when the app answered.
abstract class ServerToolSet {
  const ServerToolSet();

  /// The tools this family serves, unannotated (`name`, `description`,
  /// `inputSchema`, `outputSchema`), as `tools/list` shows them.
  List<Map<String, Object?>> get schemas;

  /// Runs [tool] for [callerSessionId] — the session the transport
  /// authenticated, null for an unattributed caller. Null hands the call on
  /// to the app; only a tool this family serves is ever asked.
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  );
}

/// The session a call is aimed at: an explicit `sessionId` is a *target*,
/// not a credential; naming nothing means the caller. The app's words.
String targetSessionOf(Map<String, dynamic> arguments, String? caller) {
  final named = arguments['sessionId'] as String?;
  if (named != null && named.trim().isNotEmpty) return named.trim();
  if (caller != null && caller.isNotEmpty) return caller;
  throw ArgumentError(
    'No sessionId, and this caller is not running inside a session, so '
    'there is no "this session" to fall back to. Pass sessionId — '
    'list_sessions has the ids.',
  );
}

/// [body] run now, as a future: a synchronous throw becomes the failed
/// future the MCP server turns into the agent's `Error:`.
Future<Object?> runTool(FutureOr<Object?> Function() body) =>
    Future<Object?>.sync(body);
