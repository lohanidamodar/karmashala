/// The relay's URL shape: a rendezvous at `v1/<id>`, the push endpoints and
/// the health check, all optionally under an access-token prefix `k/<token>`.
library;

/// Port the relay listens on when nothing says otherwise.
const int kDefaultRelayPort = 8787;

/// The API version segment every rendezvous and push route starts with.
const String kRelayApiVersion = 'v1';

/// The health check route.
const String kRelayHealthPath = 'healthz';

/// `POST` a push registration here.
const String kRelayPushRegisterPath = '$kRelayApiVersion/push/register';

/// `POST` a push request here.
const String kRelayPushPath = '$kRelayApiVersion/push';

/// The first segment of the access-token prefix: `k/<token>/…`.
const String kRelayAccessTokenSegment = 'k';

/// A rendezvous id is this many random bytes.
const int kRendezvousIdBytes = 16;

/// A rendezvous id as the relay reads it: 32 lowercase hex characters.
final RegExp rendezvousIdPattern = RegExp(
  '^[0-9a-f]{${kRendezvousIdBytes * 2}}\$',
);

/// A rendezvous route: `v1/` and a rendezvous id.
final RegExp _rendezvousPathPattern = RegExp(
  '^$kRelayApiVersion/([0-9a-f]{${kRendezvousIdBytes * 2}})\$',
);

/// The rendezvous route for [id], without a leading slash.
String rendezvousPath(String id) => '$kRelayApiVersion/$id';

/// The rendezvous id [path] names (no leading slash), or null when it names
/// none.
String? rendezvousIdOf(String path) =>
    _rendezvousPathPattern.firstMatch(path)?.group(1);

/// An access token: 32 or more url-safe characters, so it is one path segment
/// that needs no escaping and is long enough not to be guessed.
final RegExp relayAccessTokenPattern = RegExp(r'^[A-Za-z0-9_-]{32,}$');

/// Whether [token] can be a relay's access token.
bool isUsableRelayToken(String token) =>
    relayAccessTokenPattern.hasMatch(token);

/// The access-token prefix for [token], without a leading slash: `k/<token>`.
String relayAccessTokenPrefix(String token) =>
    '$kRelayAccessTokenSegment/$token';

/// [route] appended to a relay base URL's [basePath], keeping a self-hoster's
/// prefix (a reverse-proxy path, or `/k/<token>`) and dropping one trailing
/// slash from it.
String joinRelayPath(String basePath, String route) {
  final base = basePath.endsWith('/')
      ? basePath.substring(0, basePath.length - 1)
      : basePath;
  return '$base/$route';
}
