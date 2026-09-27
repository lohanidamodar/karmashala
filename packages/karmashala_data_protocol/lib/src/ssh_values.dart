import 'package:karmashala_environments/karmashala_environments.dart';

/// What the server asks a person for on a connection it is making.
enum SshPromptKind {
  /// An unknown host key: trust it or not.
  hostKey,

  /// The password of a host that logs in with one.
  password,

  /// The passphrase of an encrypted private key.
  passphrase;

  static SshPromptKind? fromName(Object? name) => switch (name) {
    'hostKey' => hostKey,
    'password' => password,
    'passphrase' => passphrase,
    _ => null,
  };
}

/// What a "test connection" at the server found: the remote's own answer on
/// success, the failure in words on the way down, and — when a host key was
/// refused — the key it presented, so a changed one can be forgotten.
final class SshTestResult {
  const SshTestResult({
    required this.connected,
    required this.message,
    this.elapsed,
    this.rejectedKey,
  });

  final bool connected;
  final String message;
  final Duration? elapsed;
  final HostKeyPresentation? rejectedKey;

  Map<String, Object?> toJson() => {
    'connected': connected,
    'message': message,
    'elapsedMs': ?elapsed?.inMilliseconds,
    if (rejectedKey != null)
      'rejectedKey': hostKeyPresentationToJson(rejectedKey!),
  };

  static SshTestResult fromJson(Map<String, Object?> json) {
    final elapsed = json['elapsedMs'];
    final rejected = json['rejectedKey'];
    return SshTestResult(
      connected: json['connected']! as bool,
      message: json['message']! as String,
      elapsed: elapsed is int ? Duration(milliseconds: elapsed) : null,
      rejectedKey: rejected is Map
          ? hostKeyPresentationFromJson(rejected.cast<String, Object?>())
          : null,
    );
  }
}

/// A presented host key as it travels: fingerprints only, never key material.
Map<String, Object?> hostKeyPresentationToJson(HostKeyPresentation key) => {
  'host': key.host,
  'port': key.port,
  'keyType': key.keyType,
  'fingerprint': key.fingerprint,
  'verdict': key.verdict.name,
  if (key.known != null) 'known': knownHostToJson(key.known!),
};

/// Throws [FormatException] on one out of shape.
HostKeyPresentation hostKeyPresentationFromJson(Map<String, Object?> json) {
  final verdict = HostKeyVerdict.values
      .where((v) => v.name == json['verdict'])
      .firstOrNull;
  final known = json['known'];
  if (verdict == null) throw const FormatException('not a host key verdict');
  return HostKeyPresentation(
    host: json['host']! as String,
    port: json['port']! as int,
    keyType: json['keyType']! as String,
    fingerprint: json['fingerprint']! as String,
    verdict: verdict,
    known: known is Map
        ? knownHostFromJson(known.cast<String, Object?>())
        : null,
  );
}

/// Where one connection stands, as the server tells it. [SshConnectionState]
/// carries no credential: its error is words already fit to show.
Map<String, Object?> sshConnectionStateToJson(SshConnectionState state) => {
  'status': state.status.name,
  'error': ?state.error,
  if (state.attempt != 0) 'attempt': state.attempt,
  'nextRetryMs': ?state.nextRetryIn?.inMilliseconds,
};

/// Throws [FormatException] on one out of shape.
SshConnectionState sshConnectionStateFromJson(Map<String, Object?> json) {
  final status = SshConnectionStatus.values
      .where((s) => s.name == json['status'])
      .firstOrNull;
  if (status == null) throw const FormatException('not a connection status');
  final retry = json['nextRetryMs'];
  return SshConnectionState(
    status: status,
    error: json['error'] as String?,
    attempt: json['attempt'] as int? ?? 0,
    nextRetryIn: retry is int ? Duration(milliseconds: retry) : null,
  );
}
