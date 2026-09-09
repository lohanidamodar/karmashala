/// The three shapes a Chrome DevTools Protocol frame can take.
///
/// One WebSocket carries request/response *and* asynchronous events. Every
/// inbound frame is exactly one of: a result for a request id, an error for a
/// request id, or an unsolicited event. Keeping that as a sealed hierarchy is
/// what lets the correlation logic be exhaustive rather than defensive.
sealed class CdpMessage {
  const CdpMessage({this.sessionId});

  /// Set when the browser is multiplexing several targets over one socket
  /// ("flat" mode). Null for a socket opened directly against one target.
  final String? sessionId;
}

/// A successful reply to the request with id [id].
class CdpResult extends CdpMessage {
  const CdpResult({required this.id, required this.result, super.sessionId});

  final int id;
  final Map<String, Object?> result;

  @override
  String toString() => 'CdpResult(#$id, ${result.keys.toList()})';
}

/// A failed reply to the request with id [id].
class CdpErrorMessage extends CdpMessage {
  const CdpErrorMessage({
    required this.id,
    required this.code,
    required this.message,
    this.data,
    super.sessionId,
  });

  final int id;
  final int code;
  final String message;
  final String? data;

  /// The wording surfaced to the user: CDP's `message` plus its optional
  /// `data`, which is usually where the useful half lives.
  String get description =>
      data == null || data!.isEmpty ? message : '$message: $data';

  @override
  String toString() => 'CdpErrorMessage(#$id, $code, $description)';
}

/// An unsolicited event such as `Page.loadEventFired`.
class CdpEvent extends CdpMessage {
  const CdpEvent({
    required this.method,
    this.params = const {},
    super.sessionId,
  });

  final String method;
  final Map<String, Object?> params;

  @override
  String toString() => 'CdpEvent($method)';
}

/// Raised when a frame cannot be parsed as CDP at all.
class CdpProtocolException implements Exception {
  const CdpProtocolException(this.message, {this.frame});

  final String message;
  final String? frame;

  @override
  String toString() => 'CdpProtocolException: $message';
}
