import 'package:agent_cli/usage.dart';
import 'package:karmashala_core/logging.dart';
import 'package:riverpod/riverpod.dart';

import '../data/agents_data.dart';

/// Sends fresh usage readings to the server's history, which keeps one row
/// per measured window worth keeping (`usageSampleWorthKeeping`) and prunes
/// as it goes. Nothing here decides what is kept.
class UsageHistoryRecorder {
  UsageHistoryRecorder(this._history);

  final UsageHistoryData _history;
  static final _log = AppLogger.named('usage.history');

  /// Records [usage] for [accountKey]. Completes with how many rows the
  /// server wrote — its change tells the charts — and a server that is away
  /// writes none, which the log says.
  Future<int> record(String accountKey, AgentUsage usage) async {
    try {
      return await _history.record(accountKey, usage);
    } on Object catch (error) {
      _log.info('Usage reading for $accountKey not recorded: $error');
      return 0;
    }
  }
}

/// Bumped whenever the history gains rows, so the charts over it re-read.
class UsageHistoryRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final usageHistoryRevisionProvider =
    NotifierProvider<UsageHistoryRevision, int>(UsageHistoryRevision.new);

final usageHistoryRecorderProvider = Provider<UsageHistoryRecorder>((ref) {
  final history = ref.watch(usageHistoryDataProvider);
  // Rows another client recorded move the charts too.
  final listening = history.recorded.listen(
    (_) => ref.read(usageHistoryRevisionProvider.notifier).bump(),
  );
  ref.onDispose(listening.cancel);
  return UsageHistoryRecorder(history);
});

/// An account's history since `from`, oldest first, asked of the server.
/// Callers round `from` (to the minute, say) so a ticking clock does not mint
/// a family member per build.
final usageHistoryProvider = FutureProvider.autoDispose
    .family<List<UsageSample>, ({String account, DateTime from})>((ref, query) {
      ref.watch(usageHistoryRevisionProvider);
      ref.watch(usageHistoryRecorderProvider);
      return ref
          .watch(usageHistoryDataProvider)
          .since(query.account, query.from);
    });
