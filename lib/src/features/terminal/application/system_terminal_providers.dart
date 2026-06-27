import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../data/system_terminal_service.dart';

/// The host-backed [SystemTerminalService] (detect + launch external terminals).
final systemTerminalServiceProvider = Provider<SystemTerminalService>(
  (ref) => SystemTerminalService(ref.watch(hostCommandRunnerProvider)),
);

/// External terminals installed on this machine, in preferred order.
final availableSystemTerminalsProvider = FutureProvider<List<SystemTerminal>>((
  ref,
) async {
  return ref.watch(systemTerminalServiceProvider).available();
});
