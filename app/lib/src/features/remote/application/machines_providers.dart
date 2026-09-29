import 'package:karmashala_remote/client.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/server/machines.dart';

/// The machines this window can be a client of (slice 5e); `main` overrides
/// it with the list kept in app support. Null in a process with none (a test,
/// a probe with no folder).
final machinesProvider = Provider<Machines?>((ref) => null);

/// The machine this window is a client of: null for this computer's own
/// server. Fixed for a server session's container — a switch of server opens
/// a new one (plan step 14).
final activeMachineProvider = Provider<CompanionPairing?>((ref) => null);

/// What the Machines section lists: every paired server elsewhere.
final pairedMachinesProvider = FutureProvider<List<CompanionPairing>>((
  ref,
) async {
  final machines = ref.watch(machinesProvider);
  return machines == null ? const [] : machines.remote();
});
