import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/application/session_ui_providers.dart';
import '../sessions/domain/session.dart';
import '../sessions/domain/session_status.dart';
import 'launcher_control_server.dart';
import 'mcp_caller_registry.dart';

/// Retires a session's MCP capability token once that session is over.
///
/// [McpCallerRegistry.forget] existed, was tested, and had no caller, so a
/// token minted for a session stayed valid for the lifetime of the process.
/// That is not a leak — the per-session config naming it is behind the same
/// owner-only ACL as the handshake file — but a session that has ended should
/// stop being speakable-for, and the config file left on disk should stop
/// being a way to speak for it.
///
/// **Which "ended", and why the distinction is the whole class.** A session
/// whose *tab* was closed is still running: `SessionAdoptionService` clears the
/// pane id and deliberately leaves the status alone, because the conversation
/// still exists and can be resumed. Taking that session's token would break an
/// agent still holding the URL. What ends a session is its status reaching a
/// terminal one, the user archiving it, or its row going away — and those are
/// exactly the three this sweeps on.
///
/// **Why it lives in `mcp/` rather than in the launcher.** The token is this
/// feature's own state, and the app already publishes "the session list
/// changed" as [sessionsRevisionProvider] — which every one of the three
/// endings bumps. Observing that is a read of `sessions/`, not an edit to it,
/// and it keeps the one place that mints tokens as the one place that retires
/// them.
class McpSessionTokenReaper {
  /// Positional, like [LauncherControlServer]'s own container: these two are
  /// what the reaper *is*, not options on it.
  McpSessionTokenReaper(this._container, this._callers, {AppLogger? logger})
    : _log = logger ?? AppLogger.named('mcp-control');

  final ProviderContainer _container;
  final McpCallerRegistry _callers;
  final AppLogger _log;

  ProviderSubscription<int>? _subscription;

  /// Starts watching the session list. Idempotent.
  void start() {
    if (_subscription != null) return;
    try {
      _subscription = _container.listen<int>(
        sessionsRevisionProvider,
        (_, _) => sweep(),
      );
    } on Object catch (error) {
      // A disposed container on the way out, exactly as in _publishStatus.
      _log.warning(
        'Could not watch the session list for ended sessions.',
        error,
      );
    }
  }

  void stop() {
    _subscription?.close();
    _subscription = null;
  }

  /// Forgets the token of every session that is over.
  ///
  /// Costs nothing until a token exists, which is what keeps this off the path
  /// of every session-list change in a workspace where no agent was ever
  /// handed an MCP URL.
  void sweep() {
    final held = _callers.sessions;
    if (held.isEmpty) return;
    try {
      final dao = _container.read(sessionDaoProvider);
      for (final sessionId in held) {
        final session = dao.getById(sessionId);
        if (session != null && !_isOver(session)) continue;
        _callers.forget(sessionId);
        _log.debug('retired the MCP token for session $sessionId');
      }
    } on Object catch (error, stack) {
      // Keeping a token a moment longer is the safe failure here; dropping one
      // out from under a live agent is not.
      _log.warning(
        'Could not sweep ended sessions for MCP tokens.',
        error,
        stack,
      );
    }
  }

  /// A row that is gone counts as over too: there is nothing left for a token
  /// to speak for.
  bool _isOver(Session session) =>
      session.isArchived ||
      session.status == SessionStatus.completed ||
      session.status == SessionStatus.failed ||
      session.status == SessionStatus.cancelled;
}
