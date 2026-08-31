/// The screens' sniff of what the user scanned, typed or pasted — only to
/// decide between an inline refusal (stay on the input screen) and the
/// pairing-progress screen (a real attempt worth narrating). The gateway does
/// its own authoritative sniff; this must never be stricter than it.
library;

import '../../remote/pairing/pairing_code.dart';

/// What a scanned or typed string looks like.
enum PairingInputKind {
  /// The full JSON payload the QR carries (or a paste of it).
  payload,

  /// The grouped base32 typed code shown under the desktop's QR.
  typedCode,

  /// Neither — the gateway will refuse it in words, inline.
  unrecognised,
}

/// Sniffs [text] the way `CompanionGateway.pairWithCode` does.
PairingInputKind classifyPairingInput(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return PairingInputKind.unrecognised;
  if (trimmed.startsWith('{')) return PairingInputKind.payload;
  if (PairingCode.looksLike(trimmed)) return PairingInputKind.typedCode;
  return PairingInputKind.unrecognised;
}
