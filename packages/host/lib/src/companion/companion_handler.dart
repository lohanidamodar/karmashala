import '../protocol/messages.dart';

/// One open pairing window: what to type, until when, the payload a QR shows,
/// and the id of the phone that paired through it — or an error when the
/// window ended without one.
typedef CompanionPairingWindow = ({
  String code,
  DateTime expiresAt,
  String payload,
  Future<String> paired,
});

/// What the host server hands companion frames to. The daemon's companion
/// implements it; the server stays free of pairing, stores and listeners, and
/// a test hands in a fake.
abstract interface class CompanionHandler {
  /// Opens a pairing window granting [capabilities], met at [relay] — empty
  /// for this host's default, or a direct pairing where it has none.
  Future<CompanionPairingWindow> openPairing({
    required int capabilities,
    required String relay,
    required bool relayIsLocal,
  });

  /// [owner] is the desktop app from now on, with its Remote access settings
  /// in [config]; frames to it go through [send].
  Future<void> adopt(
    Object owner,
    Map<String, Object?> config,
    void Function(HostMessage) send,
  );

  /// [owner]'s answer to a call forwarded to it.
  void answer(Object owner, CompanionResultMessage result);

  /// News from the desktop.
  Future<void> notice(Object owner, CompanionNoticeMessage notice);

  /// [owner] hung up.
  Future<void> detach(Object owner);
}
