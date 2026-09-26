import 'package:agent_cli/usage.dart';
import 'package:riverpod/riverpod.dart';

import '../data/agents_data.dart';

/// Bumped whenever the history gains rows, so the charts over it re-read.
class UsageHistoryRevision extends Notifier<int> {
  @override
  int build() {
    // The server records every reading it takes; its change moves the charts.
    final listening = ref
        .watch(usageHistoryDataProvider)
        .recorded
        .listen((_) => state++);
    ref.onDispose(listening.cancel);
    return 0;
  }
}

final usageHistoryRevisionProvider =
    NotifierProvider<UsageHistoryRevision, int>(UsageHistoryRevision.new);

/// An account's history since `from`, oldest first, asked of the server.
/// Callers round `from` (to the minute, say) so a ticking clock does not mint
/// a family member per build.
final usageHistoryProvider = FutureProvider.autoDispose
    .family<List<UsageSample>, ({String account, DateTime from})>((ref, query) {
      ref.watch(usageHistoryRevisionProvider);
      return ref
          .watch(usageHistoryDataProvider)
          .since(query.account, query.from);
    });
