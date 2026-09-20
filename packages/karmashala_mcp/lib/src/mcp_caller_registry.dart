import 'dart:convert';
import 'dart:math';

/// Which Karmashala session a tool call is coming *from* — stamped on the
/// process or carried in the URL, never something the model can say.
class McpCallerRegistry {
  McpCallerRegistry({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final Map<String, String> _sessionByToken = <String, String>{};
  final Map<String, String> _tokenBySession = <String, String>{};

  /// The token that names [sessionId], stable for the life of the process, so
  /// rewriting a config does not invalidate a URL an agent already holds.
  String tokenFor(String sessionId) {
    final existing = _tokenBySession[sessionId];
    if (existing != null) return existing;
    final token = generateSecret(_random);
    _tokenBySession[sessionId] = token;
    _sessionByToken[token] = sessionId;
    return token;
  }

  /// The session [token] names, or null if it names none.
  String? sessionFor(String token) => _sessionByToken[token];

  /// Every session a token has been minted for, as a snapshot — so a caller
  /// deciding which of them to [forget] can iterate while forgetting.
  List<String> get sessions => List<String>.of(_tokenBySession.keys);

  /// Retires a session's token. Called when the session is gone, so a config
  /// file left behind on disk cannot keep speaking for it.
  void forget(String sessionId) {
    final token = _tokenBySession.remove(sessionId);
    if (token != null) _sessionByToken.remove(token);
  }

  void clear() {
    _sessionByToken.clear();
    _tokenBySession.clear();
  }
}

/// 24 bytes (192 bits) from the platform CSPRNG, base64url-encoded — a
/// credential on a transport every local process can reach.
String generateSecret([Random? random]) {
  final source = random ?? Random.secure();
  return base64Url.encode(List<int>.generate(24, (_) => source.nextInt(256)));
}

/// Compares two secrets without leaking where they first differ; length is
/// folded in, so a wrong-length guess costs the same as a wrong-value one.
bool constantTimeEquals(String? actual, String expected) {
  if (actual == null) return false;
  var difference = actual.length ^ expected.length;
  final length = actual.length > expected.length
      ? actual.length
      : expected.length;
  for (var i = 0; i < length; i++) {
    final a = i < actual.length ? actual.codeUnitAt(i) : 0;
    final b = i < expected.length ? expected.codeUnitAt(i) : 0;
    difference |= a ^ b;
  }
  return difference == 0;
}
