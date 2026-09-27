import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:riverpod/riverpod.dart';

import '../../agents/data/agents_data.dart';
import 'package:karmashala_ssh/connection.dart';

/// What the last agent scan of one environment did.
class EnvironmentScan {
  const EnvironmentScan({this.busy = false, this.error, this.found});

  final bool busy;

  /// Why the scan could not be completed — a refused host key, an unreachable
  /// machine. Distinct from "found nothing", which is a successful scan.
  final String? error;

  /// How many agents the last successful scan found, or null if it has not run.
  final int? found;
}

/// Asks the server to probe **one** environment for installed agents — not
/// every one: a remote host must be dialled, and one failure belongs to one
/// environment. Only what it found is recorded; nothing it missed is judged.
/// The server dials an SSH box itself; a key to trust or a password is asked
/// through the prompt every window shows.
class EnvironmentScanController extends Notifier<Map<String, EnvironmentScan>> {
  @override
  Map<String, EnvironmentScan> build() => const {};

  EnvironmentScan scanOf(String environmentId) =>
      state[environmentId] ?? const EnvironmentScan();

  Future<void> scan(ExecutionEnvironment environment) async {
    _set(environment.id, const EnvironmentScan(busy: true));
    try {
      final report = await ref
          .read(agentWorkProvider)
          .detect(environmentId: environment.id);
      final scanned = report.environments.firstOrNull;
      if (scanned != null && !scanned.reachable) {
        throw StateError(scanned.error ?? 'Environment did not respond.');
      }
      _set(environment.id, EnvironmentScan(found: report.foundCount));
    } on DataRefused catch (refusal) {
      _set(environment.id, EnvironmentScan(error: refusal.message));
    } on Object catch (e) {
      _set(environment.id, EnvironmentScan(error: describeSshFailure(e)));
    }
  }

  void _set(String environmentId, EnvironmentScan scan) =>
      state = {...state, environmentId: scan};
}

final environmentScanControllerProvider =
    NotifierProvider<EnvironmentScanController, Map<String, EnvironmentScan>>(
      EnvironmentScanController.new,
    );
