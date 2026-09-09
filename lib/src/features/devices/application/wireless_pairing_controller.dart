import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_devices/devices.dart';
import 'device_providers.dart';

/// Which handshake is running, for the one line the dialog shows while it does.
enum WirelessPairingStep { pairing, connecting }

/// Where one wireless pairing attempt has got to.
///
/// Five states because they are five different screens, and because "paired but
/// not attached" is a half-success the user must not answer by pairing again.
sealed class WirelessPairingState {
  const WirelessPairingState();
}

/// Nothing has been asked for.
final class WirelessPairingIdle extends WirelessPairingState {
  const WirelessPairingIdle();
}

/// A QR is on screen and mDNS is being watched for the name inside it.
final class WirelessPairingWatching extends WirelessPairingState {
  const WirelessPairingWatching({required this.invite, required this.scansLeft});

  final AdbPairingInvite invite;

  /// Scans still in the budget. Shown so waiting has a visible end.
  final int scansLeft;
}

/// A handshake with the phone is in flight.
final class WirelessPairingBusy extends WirelessPairingState {
  const WirelessPairingBusy(this.step);
  final WirelessPairingStep step;
}

/// The phone is attached, and is now in the ordinary device list.
final class WirelessPairingConnected extends WirelessPairingState {
  const WirelessPairingConnected({required this.address});
  final PairingAddress address;
}

/// Paired but not attached — the phone has not said which port to connect on.
///
/// Its own state rather than a failure: the pairing is done and spending
/// another one would be wrong. [host] prefills the field that asks for the
/// port.
final class WirelessPairingPaired extends WirelessPairingState {
  const WirelessPairingPaired({required this.host, required this.message});
  final String host;
  final String message;
}

final class WirelessPairingFailed extends WirelessPairingState {
  const WirelessPairingFailed({required this.message});
  final String message;
}

/// Where a fresh QR invite comes from. A provider so a test can pin the name
/// and password that go into the code.
typedef PairingInviteFactory = AdbPairingInvite Function();

final pairingInviteFactoryProvider = Provider<PairingInviteFactory>(
  (ref) => AdbPairingInvite.generate,
);

/// How long between two `adb mdns services` polls. A provider so a test spends
/// no wall-clock time on the budget.
final mdnsPollIntervalProvider = Provider<Duration>(
  (ref) => kMdnsPollInterval,
);

/// Drives both ways of pairing a phone over Wi-Fi.
///
/// **Auto-disposed on purpose.** The QR method polls `adb mdns services`, and a
/// poll that outlives the dialog is a process created every couple of seconds
/// for a window nobody has open. The dialog holds the only listener, so its
/// unmount is what ends the poll; [cancel] is the same stop, asked for
/// explicitly.
///
/// **Bounded, not timed.** [kMdnsPollBudget] scans for the QR and
/// [kConnectDiscoveryBudget] for the connect service afterwards, so an attempt
/// has a worst case measured in processes rather than in patience.
///
/// **Nothing here logs the code or the password.** The invite prints only its
/// service name, `adb pair` is handed the code as an argument and never echoed,
/// and only the states above leave this class.
class WirelessPairingController extends Notifier<WirelessPairingState> {
  /// Bumped by every new attempt, by [cancel] and by disposal. Every await in
  /// this class is followed by a check against it, so a poll from a spent
  /// attempt cannot paint over a fresh one — the rule `PairingDialog` already
  /// uses for the remote-access code.
  int _attempt = 0;
  var _disposed = false;

  /// The armed gap between two polls. Held so it can be *cancelled* rather than
  /// left to fire into a closed dialog: an unmounted pane must leave nothing
  /// running, and a timer that wakes to discover it is unwanted still woke.
  Timer? _waitTimer;
  Completer<void>? _waiting;

  @override
  WirelessPairingState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _attempt++;
      _stopWaiting();
    });
    return const WirelessPairingIdle();
  }

  bool _spent(int attempt) => _disposed || attempt != _attempt;

  /// Waits [interval] before the next poll, interruptibly.
  Future<void> _pause(Duration interval) {
    _stopWaiting();
    final waiting = Completer<void>();
    _waiting = waiting;
    _waitTimer = Timer(interval, () {
      _waitTimer = null;
      _waiting = null;
      if (!waiting.isCompleted) waiting.complete();
    });
    return waiting.future;
  }

  /// Disarms the gap and releases whoever is in it — which then finds its
  /// attempt spent and returns without polling again.
  void _stopWaiting() {
    _waitTimer?.cancel();
    _waitTimer = null;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  /// Generates an invite, draws it, and watches mDNS for the phone that scans
  /// it. Resolves when the attempt has finished, one way or another.
  Future<void> showQrCode() async {
    final attempt = ++_attempt;
    final adb = ref.read(adbServiceProvider);
    if (adb == null) return _fail(attempt, kWirelessNoSdkMessage);

    final invite = ref.read(pairingInviteFactoryProvider)();
    state = WirelessPairingWatching(
      invite: invite,
      scansLeft: kMdnsPollBudget,
    );

    final availability = await adb.mdnsAvailability();
    if (_spent(attempt)) return;
    switch (availability) {
      case MdnsAvailability.disabled:
        return _fail(attempt, kMdnsDisabledMessage);
      case MdnsAvailability.unknown:
        return _fail(attempt, kMdnsUncheckableMessage);
      case MdnsAvailability.available:
        break;
    }

    final interval = ref.read(mdnsPollIntervalProvider);
    for (var scan = 0; scan < kMdnsPollBudget; scan++) {
      if (_spent(attempt)) return;
      state = WirelessPairingWatching(
        invite: invite,
        scansLeft: kMdnsPollBudget - scan,
      );
      final reading = await adb.mdnsServices();
      if (_spent(attempt)) return;
      final advertised = reading.find(
        type: kAdbPairingServiceType,
        name: invite.serviceName,
      );
      if (advertised != null) {
        return _pairThenAttach(
          attempt,
          adb,
          PairingAddress(host: advertised.host, port: advertised.port),
          invite.password,
        );
      }
      // Discovery stopped answering: an empty list from here is not a reading
      // of "nothing is advertising", so waiting for one is waiting for nothing.
      if (!reading.isReading) return _fail(attempt, kMdnsWentAwayMessage);
      await _pause(interval);
    }
    _fail(attempt, kNoPhoneAppearedMessage);
  }

  /// Pairs with the address and six-digit code shown by the phone's *Pair
  /// device with pairing code* screen.
  Future<void> pairWithCode({
    required String address,
    required String code,
  }) async {
    final attempt = ++_attempt;
    final adb = ref.read(adbServiceProvider);
    if (adb == null) return _fail(attempt, kWirelessNoSdkMessage);

    final parsed = parsePairingAddress(address);
    if (parsed == null) return _fail(attempt, kMalformedAddressMessage);
    if (!isPlausiblePairingCode(code)) {
      return _fail(attempt, kMalformedCodeMessage);
    }
    await _pairThenAttach(attempt, adb, parsed, code.trim());
  }

  /// Attaches an already-paired phone at the address it shows on its Wireless
  /// debugging screen — the way out of [WirelessPairingPaired].
  Future<void> connectTo(String address) async {
    final attempt = ++_attempt;
    final adb = ref.read(adbServiceProvider);
    if (adb == null) return _fail(attempt, kWirelessNoSdkMessage);

    final parsed = parsePairingAddress(address);
    if (parsed == null) return _fail(attempt, kMalformedAddressMessage);
    state = const WirelessPairingBusy(WirelessPairingStep.connecting);
    await _attachAt(attempt, adb, parsed, pairedHost: parsed.host);
  }

  /// Abandons whatever is running and forgets it. The invite dies with it.
  void cancel() {
    _attempt++;
    _stopWaiting();
    if (_disposed) return;
    state = const WirelessPairingIdle();
  }

  Future<void> _pairThenAttach(
    int attempt,
    AdbService adb,
    PairingAddress pairingPort,
    String code,
  ) async {
    state = const WirelessPairingBusy(WirelessPairingStep.pairing);
    final result = await adb.pair(pairingPort, code: code);
    if (_spent(attempt)) return;
    switch (result) {
      case AdbPairRefused(:final message):
        _fail(attempt, message);
      case AdbPaired(:final host, :final guid):
        await _findConnectPort(attempt, adb, host: host, guid: guid);
    }
  }

  /// Looks for the `_adb-tls-connect._tcp` service adb named in its pairing
  /// receipt, then connects to it. **Not the port it just paired on.**
  Future<void> _findConnectPort(
    int attempt,
    AdbService adb, {
    required String host,
    required String guid,
  }) async {
    state = const WirelessPairingBusy(WirelessPairingStep.connecting);
    final interval = ref.read(mdnsPollIntervalProvider);
    for (var scan = 0; scan < kConnectDiscoveryBudget; scan++) {
      if (_spent(attempt)) return;
      final reading = await adb.mdnsServices();
      if (_spent(attempt)) return;
      final advertised = reading.find(
        type: kAdbConnectServiceType,
        name: guid,
      );
      if (advertised != null) {
        return _attachAt(
          attempt,
          adb,
          PairingAddress(host: advertised.host, port: advertised.port),
          pairedHost: host,
        );
      }
      if (!reading.isReading) break;
      await _pause(interval);
    }
    _paired(attempt, host, kAskForTheConnectPortMessage);
  }

  Future<void> _attachAt(
    int attempt,
    AdbService adb,
    PairingAddress address, {
    required String pairedHost,
  }) async {
    final outcome = await adb.connect(address);
    if (_spent(attempt)) return;
    switch (outcome) {
      case AdbConnectOutcome.connected:
        state = WirelessPairingConnected(address: address);
        // One device list, not two: the phone shows up where every other
        // device does, and the pane is what refreshes it.
        ref.invalidate(devicesProvider);
      case AdbConnectOutcome.refused:
      case AdbConnectOutcome.unknown:
        _paired(attempt, pairedHost, connectionRefusedMessage(address));
    }
  }

  void _fail(int attempt, String message) {
    if (_spent(attempt)) return;
    state = WirelessPairingFailed(message: message);
  }

  void _paired(int attempt, String host, String message) {
    if (_spent(attempt)) return;
    state = WirelessPairingPaired(host: host, message: message);
  }
}

/// One attempt at a time — pairing is a modal act, and two invites in flight
/// would both be watching for a name only one of them chose.
final wirelessPairingProvider = NotifierProvider.autoDispose<
  WirelessPairingController,
  WirelessPairingState
>(WirelessPairingController.new);

const String kWirelessNoSdkMessage =
    'No Android SDK was found, so there is no adb to pair with. Set '
    'ANDROID_HOME, or install the SDK.';

const String kMdnsDisabledMessage =
    'adb has mDNS discovery switched off, so a phone advertising itself for '
    'pairing cannot be seen from here. Use the pairing code instead — that '
    'method needs no discovery.';

const String kMdnsUncheckableMessage =
    'Whether mDNS discovery works here could not be checked — adb did not '
    'answer. The QR code would have nothing to watch, so use the pairing code '
    'instead.';

const String kMdnsWentAwayMessage =
    'mDNS discovery stopped answering, so there is nothing left to watch for. '
    'Use the pairing code instead.';

const String kNoPhoneAppearedMessage =
    'No phone advertised itself for pairing while the code was up. On the '
    'phone, open Developer options → Wireless debugging → Pair device with QR '
    'code and scan the code. If the phone is on a different Wi-Fi network, or '
    'the network keeps its clients apart, it can never appear here.';

const String kMalformedAddressMessage =
    'That is not an address adb can use. It wants the IP address and the port, '
    'separated by a colon, exactly as the phone shows them — for example '
    '192.168.1.24:41733.';

const String kMalformedCodeMessage =
    'A pairing code is six digits. Read it off the pairing dialog on the phone '
    'exactly as shown — it changes every time that dialog is opened.';

const String kAskForTheConnectPortMessage =
    'Paired with the phone, but it has not advertised its debugging port yet. '
    'On the phone, open Wireless debugging and read the "IP address & Port" at '
    'the top of that screen — it is a different port from the one in the '
    'pairing dialog.';

/// Said when the pairing worked and the connection did not, which is almost
/// always the wrong port rather than a broken pairing.
String connectionRefusedMessage(PairingAddress address) =>
    'Paired, but nothing accepted a connection at $address. Check the "IP '
    'address & Port" on the Wireless debugging screen of the phone — it '
    'changes each time wireless debugging is switched off and on.';
