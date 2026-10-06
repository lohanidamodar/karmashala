import 'package:riverpod/riverpod.dart';

/// How many session files are being deleted from CLI stores right now, across
/// every purge: the rows are gone at once, the files go behind them.
class PurgeProgress extends Notifier<int> {
  @override
  int build() => 0;

  void started(int files) => state = state + files;

  void finished(int files) => state = state - files < 0 ? 0 : state - files;
}

final purgeProgressProvider = NotifierProvider<PurgeProgress, int>(
  PurgeProgress.new,
);
