import 'package:karmashala_core/logging.dart';
import 'package:karmashala_remote/client.dart';

import 'machines.dart';

/// The phone build's first start over a companion install (Stage 1 step 12):
/// the same app id and signature leave the companion's pairings in the same
/// secure storage, and this picks which one the app opens. Nothing is
/// granted here — a pairing without the app's grant is refused by its server
/// until the owner grants it.
///
/// Runs only while no choice was ever written, so a machine forgotten later
/// is never adopted again. Returns the machine chosen, or null.
Future<CompanionPairing?> adoptCompanionPairing(
  Machines machines, {
  AppLogger? logger,
}) async {
  if (await machines.hasChoice()) return null;
  final all = await CompanionConnections.load(machines.store);
  if (all.records.isEmpty) return null;
  // The companion's active pairing is the one mirrored under its legacy key;
  // failing that, the only one, or the set's own (the most recently used).
  final mirrored = await CompanionPairing.load(machines.store);
  final chosen =
      (mirrored == null ? null : all.byHost(mirrored.hostId.value)) ??
      (all.records.length == 1 ? all.records.single : all.active);
  if (chosen == null) return null;
  try {
    await machines.use(chosen.hostId.value);
  } on Object catch (error) {
    // The pairing screen, not a failed boot; the next start tries again.
    logger?.warning('Adopting the companion\'s pairing failed: $error');
    return null;
  }
  logger?.info(
    'Adopted the companion\'s pairing with ${chosen.hostName} '
    '(${all.records.length} paired; '
    '${chosen.capabilities.attachTier == null ? 'not yet granted the app' : 'granted the app'}).',
  );
  return chosen;
}
