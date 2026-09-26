import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../data/environments_data.dart';

export '../data/environments_data.dart'
    show EnvironmentsData, environmentsDataProvider;

/// This machine's own environment row, or null before the server has one.
/// Read from the copy and followed: a server that records it later (its own
/// start, or this app's discovery) is seen at once.
final localEnvironmentProvider = Provider<ExecutionEnvironment?>((ref) {
  final data = ref.watch(environmentsDataProvider);
  final listening = data.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(listening.cancel);
  return data
      .getAll()
      .where(
        (e) =>
            e.kind == EnvironmentKind.windowsNative ||
            e.kind == EnvironmentKind.localPosix,
      )
      .firstOrNull;
});
