import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// The config options [sessionId]'s agent exposes (a model, a flag) with the
/// value each holds, as the server last told them
/// (`SessionConfigOptionsChanged`); null until it has said. Kept in memory
/// only — the agent announces them again when the session resumes.
final sessionConfigOptionsProvider = Provider.autoDispose
    .family<SessionConfigOptionsChanged?, String>((ref, sessionId) {
      final client = ref.watch(dataClientProvider);
      final told = client.sessionConfigOptionChanges.listen((change) {
        if (change.sessionId == sessionId) ref.invalidateSelf();
      });
      ref.onDispose(told.cancel);
      return client.sessionConfigOptions[sessionId];
    });

/// Sets a session's agent config option through the server
/// (`sessions.setConfigOption`).
class SessionConfigOptionsActions {
  const SessionConfigOptionsActions(this._ref);

  final Ref _ref;

  /// Sets [configId] of [sessionId]'s agent to [value] — a choice's value or
  /// a bool. Null when the server took it; otherwise the refusal, in the
  /// server's words, for the caller to show.
  Future<String?> setOption(
    String sessionId,
    String configId,
    Object value,
  ) async {
    try {
      await _ref
          .read(dataClientProvider)
          .send(
            SessionSetConfigOption(
              sessionId: sessionId,
              configId: configId,
              value: value,
            ),
          );
      return null;
    } on DataRefused catch (refusal) {
      return refusal.message;
    }
  }
}

final sessionConfigOptionsActionsProvider =
    Provider<SessionConfigOptionsActions>(SessionConfigOptionsActions.new);
