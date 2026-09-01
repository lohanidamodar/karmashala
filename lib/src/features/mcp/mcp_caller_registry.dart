import 'dart:convert';
import 'dart:math';

/// Which Chitragupta session a tool call is coming *from*.
///
/// ## The rule this exists to keep
///
/// A caller's session identity is something the app stamped on the process,
/// never something the model can say. The stdio bridge already works that way:
/// Chitragupta puts `CHITRAGUPTA_SESSION_ID` on the agent process when it opens
/// the pane, the bridge is that agent's own child, and it forwards what it
/// inherited. The comment in the bridge puts it exactly right — it "describes
/// the actual process tree rather than something the model chose to say".
///
/// HTTP has no environment to inherit, so the same guarantee needs a different
/// carrier: the URL the agent dials. The app mints an opaque token for one
/// session and writes `http://127.0.0.1:<port>/mcp/<token>` into that session's
/// MCP config, and this registry is the map back. A session cannot claim to be
/// a different one by editing a string, because it would have to guess that
/// session's token out of 192 bits.
///
/// **The URL and not a header**, because a URL is the one field every MCP
/// client sends verbatim. Claude Code has a standing bug where `headers`
/// configured for a Streamable HTTP server never reach the request
/// (anthropics/claude-code#48514), and Codex spells its header credential a
/// third way again. A path segment needs no client to cooperate.
///
/// A caller presenting the plain server token instead — the launcher, or a
/// bridge someone started by hand — is **unattributed**, and everything that
/// would have been attributed to it says "not recorded" rather than borrowing
/// an id from somewhere else.
class McpCallerRegistry {
  McpCallerRegistry({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final Map<String, String> _sessionByToken = <String, String>{};
  final Map<String, String> _tokenBySession = <String, String>{};

  /// The token that names [sessionId], minted on first ask.
  ///
  /// Stable for the life of the process, so re-writing a session's config does
  /// not invalidate the URL an agent is already holding.
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

/// 24 bytes (192 bits) from the platform CSPRNG, base64url-encoded.
///
/// The same size and source as the control server's own tokens, and for the
/// same reason: these are credentials on a transport every local process can
/// reach, so a predictable one would be the whole boundary.
String generateSecret([Random? random]) {
  final source = random ?? Random.secure();
  return base64Url.encode(List<int>.generate(24, (_) => source.nextInt(256)));
}

/// Compares two secrets without leaking where they first differ.
///
/// Length is folded in rather than short-circuited on, so a wrong-length guess
/// costs the same as a wrong-value one.
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
