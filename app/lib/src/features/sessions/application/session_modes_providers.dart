import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// The modes [sessionId]'s agent offers and the one it is in, as the server
/// last told them (`SessionModesChanged`); null until it has said. Kept in
/// memory only — the agent announces them again when the session resumes.
final sessionModesProvider = Provider.autoDispose
    .family<SessionModesChanged?, String>((ref, sessionId) {
      final client = ref.watch(dataClientProvider);
      final told = client.sessionModeChanges.listen((change) {
        if (change.sessionId == sessionId) ref.invalidateSelf();
      });
      ref.onDispose(told.cancel);
      return client.sessionModes[sessionId];
    });

/// Sets a session's agent mode through the server (`sessions.setMode`).
class SessionModesActions {
  const SessionModesActions(this._ref);

  final Ref _ref;

  /// Puts [sessionId]'s agent into [modeId]. Null when the server took it;
  /// otherwise the refusal, in the server's words, for the caller to show.
  Future<String?> setMode(String sessionId, String modeId) async {
    try {
      await _ref
          .read(dataClientProvider)
          .send(SessionSetMode(sessionId: sessionId, modeId: modeId));
      return null;
    } on DataRefused catch (refusal) {
      return refusal.message;
    }
  }
}

final sessionModesActionsProvider = Provider<SessionModesActions>(
  SessionModesActions.new,
);
