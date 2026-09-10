/// Everything the remote link is made of, in one import. Prefer a narrower
/// entry when you know which half you need.
///
/// **Two names live at both layers, and this library carries the lower one.**
/// `CompanionPairing` and `PairingException` each name a different type in
/// `companion.dart`, so a barrel cannot offer both — import it directly.
library;

export 'client.dart';
export 'companion.dart' hide CompanionPairing, PairingException;
export 'host.dart';
export 'pairing.dart';
export 'push.dart';
export 'remote.dart';
