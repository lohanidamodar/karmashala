import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/companion.dart';

import '../application/companion_providers.dart';

/// The machine this phone is connected to, by the name it gave — a desktop
/// running the app and a server with no desktop alike — or "this machine"
/// before it has said. What a sentence about where sessions run names, so
/// none of them claims a desktop a server does not have.
String companionMachineNameOf(CompanionPairing? pairing) {
  final name = pairing?.hostName?.trim();
  return name == null || name.isEmpty ? 'this machine' : name;
}

/// [companionMachineNameOf] the active pairing, watched: call it in `build`.
String watchCompanionMachineName(WidgetRef ref) => companionMachineNameOf(
  ref.watch(companionPairingProvider).asData?.value ??
      ref.watch(companionGatewayProvider).pairing,
);

/// [companionMachineNameOf] the active pairing, read once: for callbacks.
String readCompanionMachineName(WidgetRef ref) =>
    companionMachineNameOf(ref.read(companionGatewayProvider).pairing);
