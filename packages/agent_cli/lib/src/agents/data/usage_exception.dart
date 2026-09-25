import '../domain/usage_failure.dart';

/// Raised when a usage lookup cannot complete.
///
/// [kind] is what the surfaces switch on: a rate limit, an expired token and an
/// unreachable endpoint are three different situations for the user, and for
/// years they arrived here as one grey dash. [message] stays the sentence a
/// human reads.
class UsageException implements Exception {
  UsageException(
    this.message, {
    this.kind = UsageFailureKind.unusable,
    this.retryIn,
  });

  final String message;

  final UsageFailureKind kind;

  /// How long until this account may ask again. Only ever set for
  /// [UsageFailureKind.rateLimited] — every other failure may be retried by the
  /// next tick.
  final Duration? retryIn;

  @override
  String toString() => 'UsageException: $message';
}
