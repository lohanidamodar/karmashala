/// What the host server hands a `serverCall` to: the paired devices, revoking
/// one, and the agent CLIs this machine has. The server stays free of stores
/// and probes; `serve` supplies the one real implementation
/// ([ServerAdministration]) and a test a fake.
abstract interface class ServerAdmin {
  /// Answers [method] (one of `ServerMethod`) with [arguments]. Throws
  /// [ServerCallRefused] with the sentence to refuse with.
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> arguments,
  );
}

/// A server call that was refused, in words a person reads.
class ServerCallRefused implements Exception {
  const ServerCallRefused(this.message);

  final String message;

  @override
  String toString() => message;
}
