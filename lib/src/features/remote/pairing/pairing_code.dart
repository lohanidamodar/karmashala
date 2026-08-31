/// The human-typeable pairing code: 20 random bytes as 32 base32 characters,
/// grouped for reading (`K7QM-3X2W-…`).
///
/// The code carries ONLY the secret. It is full entropy (160 bits), so — unlike
/// croc's short PAKE codes — it cannot be brute-forced by whoever runs the
/// relay and needs no SPAKE2 (which remains descoped: no vetted pure-Dart
/// implementation). Everything else the QR payload carries is derived from the
/// secret (rendezvous), configured on the phone (relay), or delivered in the
/// host's sealed confirm (host id, name, granted capabilities).
library;

import 'dart:typed_data';

import '../transport/key_schedule.dart';

/// RFC 4648 base32 — no 0/1/8/9, so nothing looks like a letter.
const String kPairingCodeAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// 20 bytes → exactly this many base32 characters, no padding.
const int kPairingCodeChars = kTypedCodeSecretBytes * 8 ~/ 5;

/// Characters per typed group (`XXXX-XXXX-…`, eight groups).
const int kPairingCodeGroup = 4;

/// Encoding, decoding and sniffing of the typed pairing code.
class PairingCode {
  const PairingCode._();

  /// The grouped, typeable form: `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`.
  static String encode(List<int> secret) {
    if (secret.length != kTypedCodeSecretBytes) {
      throw ArgumentError.value(
        secret.length,
        'secret',
        'must be $kTypedCodeSecretBytes bytes',
      );
    }
    return groups(secret).join('-');
  }

  /// The eight 4-character groups, for a display that wants its own layout.
  static List<String> groups(List<int> secret) {
    final flat = base32Encode(secret);
    return [
      for (var i = 0; i < flat.length; i += kPairingCodeGroup)
        flat.substring(i, i + kPairingCodeGroup),
    ];
  }

  /// Parses whatever the user typed — dashes, spaces and case are forgiven —
  /// or returns null when it is not a pairing code.
  static Uint8List? tryDecode(String text) {
    final stripped = text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    if (stripped.length != kPairingCodeChars) return null;
    return base32Decode(stripped);
  }

  /// Whether [text] is base32-ish enough to be a typed code (vs a pasted
  /// JSON payload, which starts with `{`).
  static bool looksLike(String text) => tryDecode(text) != null;

  /// Unpadded RFC 4648 base32 of a whole number of 5-byte blocks.
  static String base32Encode(List<int> bytes) {
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | (byte & 0xff);
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(kPairingCodeAlphabet[(buffer >> bits) & 0x1f]);
      }
    }
    if (bits > 0) {
      out.write(kPairingCodeAlphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    return out.toString();
  }

  /// Strict decode of unpadded uppercase base32, or null on any bad character
  /// or a length that is not a whole number of bytes.
  static Uint8List? base32Decode(String text) {
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final unit in text.codeUnits) {
      final index = kPairingCodeAlphabet.indexOf(String.fromCharCode(unit));
      if (index < 0) return null;
      buffer = (buffer << 5) | index;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
    }
    // Leftover bits must be padding zeros of an exact byte count.
    if (bits >= 5 || (buffer & ((1 << bits) - 1)) != 0) return null;
    return Uint8List.fromList(out);
  }
}
