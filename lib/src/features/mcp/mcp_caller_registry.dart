import 'dart:convert';
import 'dart:math';

/// Which Karmashala session a tool call is coming *from*.
///
/// A caller's identity is stamped on the process by the app, never said by the
/// model: the stdio bridge inherits `KARMASHALA_SESSION_ID`, and HTTP — which
/// has no environment — carries it in the URL as `/mcp/<token>`, minted per
/// session and mapped back here. Claiming another session would mean guessing
/// 192 bits.
///
/// **The URL and not a header**, because a URL is the one field every MCP client
/// sends verbatim: Claude Code never attaches configured `headers`
/// (anthropics/claude-code#48514). A caller presenting the plain server token is
/// **unattributed**, and anything attributable to it reads "not recorded".
class McpCallerRegistry {
  McpCallerRegistry({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final Map<String, String> _sessionByToken = <String, String>{};
  final Map<String, String> _tokenBySession = <String, String>{};

  /// The token that names [sessionId], minted on first ask and stable for the
  /// life of the process, so re-writing a session's config does not invalidate
  /// the URL an agent is already holding.
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

/// 24 bytes (192 bits) from the platform CSPRNG, base64url-encoded. The same
/// size and source as the control server's own tokens: these are credentials on
/// a transport every local process can reach.
String generateSecret([Random? random]) {
  final source = random ?? Random.secure();
  return base64Url.encode(
    List<int>.generate(24, (_) => source.nextInt(256)),
  );
}

/// Compares two secrets without leaking where they first differ. Length is
/// folded in rather than short-circuited on, so a wrong-length guess costs the
/// same as a wrong-value one.
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
