import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'mcp_caller_registry.dart';

/// Who a presented credential says is calling, or null when it names nobody.
abstract interface class McpCallerLookup {
  String? sessionFor(String token);
}

/// Caller credentials derived from one persisted secret, so a token outlives
/// the process that issued it and the app can issue one synchronously at launch.
class McpCallerKey implements McpCallerLookup {
  McpCallerKey(this.secret);

  /// A fresh 192-bit secret.
  factory McpCallerKey.generate([Random? random]) =>
      McpCallerKey(generateSecret(random));

  /// base64url; the whole boundary, so it lives only in owner-only files.
  final String secret;

  /// `<sessionId>.<mac>`: the same token for the same session, every time.
  String tokenFor(String sessionId) => '$sessionId.${_mac(sessionId)}';

  /// The session [token] was issued for, or null when this key never issued it.
  @override
  String? sessionFor(String token) {
    final dot = token.lastIndexOf('.');
    if (dot <= 0 || dot == token.length - 1) return null;
    final sessionId = token.substring(0, dot);
    final mac = token.substring(dot + 1);
    return constantTimeEquals(mac, _mac(sessionId)) ? sessionId : null;
  }

  String _mac(String sessionId) {
    final digest = Hmac(
      sha256,
      utf8.encode(secret),
    ).convert(utf8.encode('karmashala-mcp-caller:$sessionId'));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
