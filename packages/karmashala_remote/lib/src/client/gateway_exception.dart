/// A refused or failed gateway call. Carries a sentence fit to show the user.
class GatewayException implements Exception {
  const GatewayException(this.message);

  final String message;

  @override
  String toString() => 'GatewayException: $message';
}
