/// Everything the remote link is made of, in one import.
///
/// Prefer a narrower entry when you know which half you need — `remote.dart`
/// for the wire, `host.dart` for the desktop's side, `client.dart` and
/// `companion.dart` for the phone's.
///
/// **Two names live at both layers, and this library carries the lower one.**
/// `CompanionPairing` is the pairing *record at rest* in `client.dart` and the
/// pairing *the UI is showing* in `companion.dart`; `PairingException` is the
/// host's refusal in `pairing.dart` and the gateway's user-fit sentence in
/// `companion.dart`. They are different types with the same names — the app
/// already imports one of them with a prefix for exactly this reason — so a
/// barrel cannot offer both. Import `companion.dart` directly for the gateway's
/// pair; renaming either is a change to the app's code, not to this packaging.
library;

export 'client.dart';
export 'companion.dart' hide CompanionPairing, PairingException;
export 'host.dart';
export 'pairing.dart';
export 'push.dart';
export 'remote.dart';
