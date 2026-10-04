import 'dart:async';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_status_providers.dart';

/// Why a session's subagents cannot be listed, in words for the panel.
class SessionSubagentsUnavailable implements Exception {
  const SessionSubagentsUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the panel says when asking failed for a reason the server gave no
/// words for (the connection dropped, the answer was out of shape).
const String kSubagentsUnreadable =
    "Couldn't read this session's subagents. Close the panel and open it "
    'again to retry.';

/// How often an open panel asks again while a delegate is live: its record
/// moves without a notice whenever its parent's chat is not on screen.
const Duration kSubagentsRefresh = Duration(seconds: 3);

/// When to ask again unprompted after [list], or null: only while an entry
/// is running or blocked, since each ask re-reads records and tokens.
Duration? subagentsRefreshAfter(SessionSubagentList list) =>
    _anyLive(list.entries) ? kSubagentsRefresh : null;

bool _anyLive(List<SessionSubagent> entries) => entries.any(
  (entry) => entry.state.isLive || _anyLive(entry.children),
);

/// Session [sessionId]'s subagents and child sessions, as the server reads
/// them (`sessions.subagents`): asked again on a notice of its transcript or
/// of the session rows, and every [kSubagentsRefresh] while one is live.
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
        Duration? after;
        try {
          final list = (await client.send(
            SessionSubagentsRead(sessionId),
          )).value;
          after = subagentsRefreshAfter(list);
          if (!disposed) out.add(list);
        } on DataRefused catch (refusal) {
          if (!disposed) {
            out.addError(SessionSubagentsUnavailable(refusal.message));
          }
        } on Object {
          // Any other failure ends the spinner too; a later notice asks again.
          if (!disposed) {
            out.addError(const SessionSubagentsUnavailable(kSubagentsUnreadable));
          }
        } finally {
          asking = false;
          if (!disposed) {
            if (askAgain) {
              askAgain = false;
              unawaited(ask());
            } else if (after != null) {
              next = Timer(after, () => unawaited(ask()));
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

/// The child sessions of session [String] working now (not archived), by
/// id: what Stop on the parent offers to stop too.
final runningChildSessionsProvider = Provider.autoDispose
    .family<List<String>, String>((ref, sessionId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
      });
      return [
        for (final row in ref.read(sessionsDataProvider).getAll())
          if (row.parentSessionId == sessionId &&
              !row.isArchived &&
              row.status.claimsLive &&
              _working(
                ref.watch(
                  agentSessionStatusProvider(
                    row.id,
                  ).select((report) => report.asData?.value.status),
                ),
              ))
            row.id,
      ];
    });

bool _working(AgentActivityStatus? status) =>
    status == AgentActivityStatus.working ||
    status == AgentActivityStatus.awaitingApproval;

/// How many child sessions session [String] has (not archived), and how many
/// of those are working now. Read from the rows and their statuses this app
/// already holds, so a status line can show it without asking the server;
/// an agent's own in-turn subagents are in the panel, not counted here.
final sessionChildCountProvider = Provider.autoDispose
    .family<({int count, int running}), String>((ref, sessionId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
      });
      var count = 0;
      var running = 0;
      for (final row in ref.read(sessionsDataProvider).getAll()) {
        if (row.parentSessionId != sessionId || row.isArchived) continue;
        count++;
        if (!row.status.claimsLive) continue;
        final status = ref.watch(
          agentSessionStatusProvider(
            row.id,
          ).select((report) => report.asData?.value.status),
        );
        if (status == AgentActivityStatus.working ||
            status == AgentActivityStatus.awaitingApproval) {
          running++;
        }
      }
      return (count: count, running: running);
    });
