import 'package:riverpod/riverpod.dart';

import '../domain/decision_record.dart';
import 'session_providers.dart';

/// Bumped whenever a decision is appended, so the panel refreshes without
/// polling. The record changes at exactly four moments — an approval answered,
/// a verification finished, a checkpoint labelled, somebody recording one — and
/// each of those is a write we are already inside of.
class DecisionsRevisionController extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state = state + 1;
}

final decisionsRevisionProvider =
    NotifierProvider<DecisionsRevisionController, int>(
      DecisionsRevisionController.new,
    );

/// A session's decision record, **oldest first** — the order the record is
/// meant in and the order the handoff packet renders, because the early rows
/// are the constraints everything since was built on. `autoDispose` and read
/// only by the panel, so a closed panel holds no subscription and costs no
/// query.
final sessionDecisionsProvider = Provider.autoDispose
    .family<List<DecisionRecord>, String>(
      (ref, sessionId) {
        ref.watch(decisionsRevisionProvider);
        return ref.watch(decisionRecordDaoProvider).forSession(sessionId);
      },
    );
