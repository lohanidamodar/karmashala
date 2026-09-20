import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../settings/application/settings_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

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

/// The terminal app used to resume sessions: the configured custom exe, the
/// chosen detected terminal, or the first detected one. `null` if none.
final defaultSystemTerminalProvider = FutureProvider<SystemTerminal?>((
  ref,
) async {
  final settings = ref.watch(settingsControllerProvider);
  final id = settings.defaultSystemTerminalId;
  if (id == 'custom') {
    final path = settings.customTerminalPath;
    if (path != null && path.trim().isNotEmpty) {
      return customSystemTerminal(path.trim());
    }
  }
  final available = await ref.watch(availableSystemTerminalsProvider.future);
  if (id != null) {
    for (final terminal in available) {
      if (terminal.id == id) return terminal;
    }
  }
  return available.isEmpty ? null : available.first;
});
