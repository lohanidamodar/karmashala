import 'package:riverpod/riverpod.dart';

import 'package:karmashala_session/events.dart';
import 'session_providers.dart';

/// Bumped whenever a decision is appended, so the panel refreshes without
/// polling: the record only changes inside a write we are already making.
class DecisionsRevisionController extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state = state + 1;
}

final decisionsRevisionProvider =
    NotifierProvider<DecisionsRevisionController, int>(
      DecisionsRevisionController.new,
    );

/// A session's decision record, **oldest first** — the order the handoff packet
/// renders, because the early rows are the constraints the rest was built on.
final sessionDecisionsProvider = Provider.autoDispose
    .family<List<DecisionRecord>, String>((ref, sessionId) {
      ref.watch(decisionsRevisionProvider);
      return ref.watch(decisionRecordDaoProvider).forSession(sessionId);
    });
