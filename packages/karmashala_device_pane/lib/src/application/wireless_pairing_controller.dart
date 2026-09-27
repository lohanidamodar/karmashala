import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:riverpod/riverpod.dart';

import 'device_providers.dart';

/// Where a fresh QR invite comes from. A provider so a test can pin the name
/// and password that go into the code.
final pairingInviteFactoryProvider = Provider<PairingInviteFactory>(
  (ref) => AdbPairingInvite.generate,
);

/// How long between two `adb mdns services` polls. A provider so a test spends
/// no wall-clock time on the budget.
final mdnsPollIntervalProvider = Provider<Duration>((ref) => kMdnsPollInterval);

/// The pane's [WirelessPairingFlow]. Auto-disposed: the QR method polls
/// `adb mdns services`, and a poll outliving the dialog spawns on.
class WirelessPairingController extends Notifier<WirelessPairingState> {
  late WirelessPairingFlow _flow;

  @override
  WirelessPairingState build() {
    final flow = _flow = WirelessPairingFlow(
      adb: () => ref.read(adbServiceProvider),
      invites: ref.read(pairingInviteFactoryProvider),
      pollInterval: ref.read(mdnsPollIntervalProvider),
      onConnected: () => ref.invalidate(devicesProvider),
    );
    flow.onChanged = (next) => state = next;
    ref.onDispose(flow.dispose);
    return flow.state;
  }

  Future<void> showQrCode() => _flow.showQrCode();

  Future<void> pairWithCode({required String address, required String code}) =>
      _flow.pairWithCode(address: address, code: code);

  Future<void> connectTo(String address) => _flow.connectTo(address);

  void cancel() => _flow.cancel();
}

/// One attempt at a time — pairing is a modal act, and two invites in flight
/// would both be watching for a name only one of them chose.
final wirelessPairingProvider =
    NotifierProvider.autoDispose<
      WirelessPairingController,
      WirelessPairingState
    >(WirelessPairingController.new);
