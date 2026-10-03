import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

final _log = AppLogger.named('sessions.queue');

/// The messages [sessionId] holds at the server — queued, delivering and
/// failed — in the order they go. Empty against a server without
/// `sessions.queue`. Listed once, then kept by `sessionQueueChanged`, and
/// listed again after the link comes back.
final sessionQueueProvider = Provider.autoDispose
    .family<List<QueuedMessage>, String>((ref, sessionId) {
      if (!ref.watch(capabilitiesProvider.select((c) => c.sessionQueue))) {
        return const [];
      }
      final client = ref.watch(dataClientProvider);
      var disposed = false;
      final told = client.sessionQueueChanges.listen((change) {
        if (change.sessionId == sessionId) ref.invalidateSelf();
      });
      final relinked = client.connectionChanges.listen((connection) {
        if (connection.state == DataLinkState.connected) ref.invalidateSelf();
      });
      ref.onDispose(() {
        disposed = true;
        told.cancel();
        relinked.cancel();
      });
      final held = client.sessionQueues[sessionId];
      if (held != null) return held;
      unawaited(() async {
        try {
          final listed = (await client.send(SessionQueueList(sessionId))).value;
          // A change that landed meanwhile is newer than this answer.
          client.sessionQueues.putIfAbsent(sessionId, () => listed);
          if (!disposed) ref.invalidateSelf();
        } on Object catch (error) {
          _log.info('Could not list the queue of $sessionId: $error');
        }
      }());
      return const [];
    });

/// Edits and cancels a session's queued messages at the server; what moved
/// comes back as `sessionQueueChanged`. Throws [DataRefused] in words.
class SessionQueueActions {
  SessionQueueActions(this._ref);

  final Ref _ref;

  Future<void> edit(String sessionId, String id, String text) => _ref
      .read(dataClientProvider)
      .send(SessionQueueEdit(sessionId: sessionId, id: id, text: text));

  Future<void> cancel(String sessionId, String id) => _ref
      .read(dataClientProvider)
      .send(SessionQueueCancel(sessionId: sessionId, id: id));
}

final sessionQueueActionsProvider = Provider<SessionQueueActions>(
  SessionQueueActions.new,
);
