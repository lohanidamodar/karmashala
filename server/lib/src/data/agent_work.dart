import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers the work a client asks the server to do for its agents
/// (`AgentWorkRequest`: usage, accounts, detection, the CLI import) — the
/// server's agent components, set once `serve` has built them.
abstract interface class AgentWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(AgentWorkRequest<Object?> request);

  /// Every account's usage as last read, for `agents.list`.
  List<AccountUsageState> usageStates();
}
