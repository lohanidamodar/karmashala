import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_devices/providers.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/application/session_ui_providers.dart';
import 'package:karmashala_mcp/protocol.dart';

/// Retires a session's MCP token, and the devices it drove, once that session
/// is over. A closed *tab* is not over — taking that token would break an agent
/// still holding the URL. Without [_callers] — the session host issues tokens
/// and refuses an over session's itself — only device claims are released.
class McpSessionTokenReaper {
  McpSessionTokenReaper(this._container, this._callers, {AppLogger? logger})
    : _log = logger ?? AppLogger.named('mcp-control');

  final ProviderContainer _container;
  final McpCallerRegistry? _callers;
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

  /// Forgets the token of every session that is over, and drops the devices it
  /// was driving: one place decides "ended", so the two answers cannot differ.
  void sweep() {
    try {
      final claims = _container.read(deviceClaimsProvider);
      final held =
          _callers?.sessions ??
          {for (final c in claims.standingClaims) c.holderSessionId};
      if (held.isEmpty) return;
      final dao = _container.read(sessionDaoProvider);
      for (final sessionId in held) {
        final session = dao.getById(sessionId);
        if (session != null && !session.isOver) continue;
        _callers?.forget(sessionId);
        claims.release(sessionId);
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
}
