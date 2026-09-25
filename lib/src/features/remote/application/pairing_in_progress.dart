import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

/// One pairing window the dialog is showing, whoever runs it — the session
/// host, or this app's own server where there is no host: the payload the QR
/// draws, and the phone that paired through it.
class PairingInProgress {
  const PairingInProgress({required this.payload, required this.done});

  /// A window this app's own server opened.
  PairingInProgress.of(HostPairingSession session)
    : payload = session.payload,
      done = session.done;

  final PairingPayload payload;

  /// Completes with the stored device, or fails with a `PairingException`
  /// when the window ended without one.
  final Future<PairedDevice> done;
}
