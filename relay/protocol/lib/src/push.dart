/// The relay's two push endpoints: the bodies a client posts and the statuses
/// the relay answers with.
library;

/// A push tag: 32 lowercase hex characters. Opaque — the client derives it,
/// and it is never a device id or a rendezvous.
final RegExp pushTagPattern = RegExp(r'^[0-9a-f]{32}$');

/// What a push payload may contain: base64url.
final RegExp pushPayloadPattern = RegExp(r'^[A-Za-z0-9_=-]+$');

/// The platforms a push token can belong to.
const Set<String> kPushPlatforms = {'android', 'ios'};

/// Longest push token the relay stores.
const int kMaxPushTokenLength = 4096;

/// `POST /v1/push/register` `{tag, token, platform}`: store [token] under
/// [tag].
class PushRegistration {
  const PushRegistration({
    required this.tag,
    required this.token,
    required this.platform,
  });

  final String tag;
  final String token;
  final String platform;

  Map<String, Object?> toJson() => {
    'tag': tag,
    'token': token,
    'platform': platform,
  };

  /// The registration [body] carries, or null when it breaks a rule — which
  /// the relay answers [RelayStatus.badRequest].
  static PushRegistration? tryParse(Map<String, Object?> body) {
    final tag = body['tag'];
    final token = body['token'];
    final platform = body['platform'];
    if (tag is! String ||
        !pushTagPattern.hasMatch(tag) ||
        token is! String ||
        token.isEmpty ||
        token.length > kMaxPushTokenLength ||
        platform is! String ||
        !kPushPlatforms.contains(platform)) {
      return null;
    }
    return PushRegistration(tag: tag, token: token, platform: platform);
  }
}

/// `POST /v1/push` `{tag, payload}`: deliver [payload] — opaque base64url
/// ciphertext — to whoever registered [tag].
class PushRequest {
  const PushRequest({required this.tag, required this.payload});

  final String tag;
  final String payload;

  Map<String, Object?> toJson() => {'tag': tag, 'payload': payload};

  /// The request [body] carries, or null when it breaks a rule — which the
  /// relay answers [RelayStatus.badRequest]. The size cap is the relay's own
  /// setting and is checked after this.
  static PushRequest? tryParse(Map<String, Object?> body) {
    final tag = body['tag'];
    final payload = body['payload'];
    if (tag is! String ||
        !pushTagPattern.hasMatch(tag) ||
        payload is! String ||
        payload.isEmpty ||
        !pushPayloadPattern.hasMatch(payload)) {
      return null;
    }
    return PushRequest(tag: tag, payload: payload);
  }
}

/// The HTTP statuses the relay answers with.
abstract final class RelayStatus {
  /// A push registration was stored.
  static const int pushRegistered = 204;

  /// A push was handed to the delivery service.
  static const int pushAccepted = 202;

  /// An unknown route — a wrong access token reads the same — or, from
  /// `/v1/push`, an unknown tag (the relay restarted; register and retry).
  static const int notFound = 404;

  /// The push service says the token is gone; the registration was dropped.
  static const int tokenGone = 410;

  /// Push delivery is not configured, or the relay holds all it will.
  static const int unavailable = 503;

  /// The rendezvous already holds two sockets.
  static const int rendezvousBusy = 409;

  /// Too many requests from one client.
  static const int slowDown = 429;

  /// A body or payload above the cap.
  static const int tooLarge = 413;

  /// A body that breaks a rule.
  static const int badRequest = 400;

  /// A push endpoint asked with anything but `POST`.
  static const int methodNotAllowed = 405;

  /// The push service refused for some other reason.
  static const int deliveryFailed = 502;
}
