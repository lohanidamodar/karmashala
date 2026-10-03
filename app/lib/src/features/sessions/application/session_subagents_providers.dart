import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import 'session_signals.dart';

/// Why a session's subagents cannot be listed, in words for the panel.
class SessionSubagentsUnavailable implements Exception {
  const SessionSubagentsUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How often an open panel asks again: a subagent's record moves without a
/// notice whenever its parent's chat is not on screen.
const Duration kSubagentsRefresh = Duration(seconds: 3);

/// Session [sessionId]'s subagents and child sessions, as the server reads
/// them (`sessions.subagents`): asked again on a notice of its transcript or
/// of the session rows, and every [kSubagentsRefresh] while anyone watches.
final sessionSubagentsProvider = StreamProvider.autoDispose
    .family<SessionSubagentList, String>((ref, sessionId) {
      if (!ref.read(capabilitiesProvider).serverOffers('sessions.subagents')) {
        return Stream.error(
          const SessionSubagentsUnavailable(
            'This server does not list subagents. Update it to see them here.',
          ),
        );
      }
      final client = ref.watch(dataClientProvider);
      final out = StreamController<SessionSubagentList>();
      var disposed = false;
      var asking = false;
      var askAgain = false;
      Timer? next;

      Future<void> ask() async {
        if (disposed) return;
        if (asking) {
          askAgain = true;
          return;
        }
        asking = true;
        next?.cancel();
        try {
          final list = (await client.send(
            SessionSubagentsRead(sessionId),
          )).value;
          if (!disposed) out.add(list);
        } on DataRefused catch (refusal) {
          if (!disposed) {
            out.addError(SessionSubagentsUnavailable(refusal.message));
          }
        } finally {
          asking = false;
          if (!disposed) {
            if (askAgain) {
              askAgain = false;
              unawaited(ask());
            } else {
              next = Timer(kSubagentsRefresh, () => unawaited(ask()));
            }
          }
        }
      }

      final notices = client.transcriptChanges
          .where((change) => change.sessionId == sessionId)
          .listen((_) => unawaited(ask()));
      ref.listen(sessionsRevisionProvider, (_, _) => unawaited(ask()));
      ref.onDispose(() {
        disposed = true;
        next?.cancel();
        unawaited(notices.cancel());
        unawaited(out.close());
      });
      unawaited(ask());
      return out.stream;
    });
