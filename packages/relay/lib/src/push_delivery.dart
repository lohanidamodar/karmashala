/// The delivery boundary behind `/v1/push`.
///
/// The relay hands an accepted push request — a stored token and an opaque
/// payload it cannot read — to one of these. Tests plug in a fake; the binary
/// plugs in [FcmHttpV1Sender] when an operator configured a service account,
/// and nothing at all otherwise.
library;

/// Delivers one opaque payload to one device's push service.
abstract interface class PushDelivery {
  /// Sends [payload] (base64url ciphertext, opaque here and to the push
  /// service) to the device holding [token] on [platform].
  ///
  /// Throws [PushTokenGoneException] when the service says the token no
  /// longer exists, and [PushDeliveryException] for any other failure.
  Future<void> deliver({
    required String token,
    required String platform,
    required String payload,
  });
}

/// Delivery failed. The message never quotes a token or a payload.
class PushDeliveryException implements Exception {
  const PushDeliveryException(this.message);

  final String message;

  @override
  String toString() => 'PushDeliveryException: $message';
}

/// The push service no longer knows this token — the app was uninstalled or
/// the token rotated. The relay drops the registration on hearing this.
class PushTokenGoneException extends PushDeliveryException {
  const PushTokenGoneException() : super('token is gone');
}
