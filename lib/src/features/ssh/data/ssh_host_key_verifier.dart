import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import '../domain/ssh_host_key.dart';
import 'known_host_dao.dart';

/// Asked when a host presents a key we have never seen. Returning `true` trusts
/// it from now on (trust on first use); anything else refuses the connection.
///
/// It is only ever called for [HostKeyVerdict.unknown]. A **changed** key is
/// never offered to the user for approval.
typedef HostKeyTrustDecision =
    FutureOr<bool> Function(HostKeyPresentation presentation);

/// Decides whether to accept the host key a server presented.
///
/// The policy, deliberately the same one OpenSSH uses:
///
/// * **known and matching** → accept silently.
/// * **unknown** → ask [onUnknownHostKey]. With no handler wired the answer is
///   *no*: an unattended connection never blindly trusts a new host.
/// * **changed** → refuse, always, without asking. A different key on an address
///   we have already pinned is the man-in-the-middle signal, and an interface
///   that lets a user click through it is not host key verification.
///
/// The verifier logs fingerprints and addresses only — never key material and
/// never credentials.
class SshHostKeyVerifier {
  SshHostKeyVerifier({
    required this.knownHosts,
    required this.host,
    required this.port,
    required this.clock,
    this.onUnknownHostKey,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('ssh.hostkey');

  final KnownHostDao knownHosts;
  final String host;
  final int port;
  final Clock clock;
  final HostKeyTrustDecision? onUnknownHostKey;
  final AppLogger _logger;

  /// The most recent presentation, kept so a refused connection can explain
  /// itself precisely instead of surfacing a bare handshake error.
  HostKeyPresentation? lastPresentation;

  /// Classifies [fingerprint] without touching the store or prompting.
  HostKeyPresentation classify(String keyType, String fingerprint) {
    final known = knownHosts.find(host, port);
    final verdict = known == null
        ? HostKeyVerdict.unknown
        : (known.fingerprint == fingerprint && known.keyType == keyType
              ? HostKeyVerdict.trusted
              : HostKeyVerdict.changed);
    return HostKeyPresentation(
      host: host,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
      verdict: verdict,
      known: known,
    );
  }

  /// The `dartssh2` callback. [fingerprintBytes] is the UTF-8 of the
  /// OpenSSH-style `SHA256:<base64>` fingerprint.
  Future<bool> verify(String keyType, Uint8List fingerprintBytes) async {
    final fingerprint = utf8.decode(fingerprintBytes, allowMalformed: true);
    final presentation = classify(keyType, fingerprint);
    lastPresentation = presentation;

    switch (presentation.verdict) {
      case HostKeyVerdict.trusted:
        return true;

      case HostKeyVerdict.changed:
        // Never prompted, never auto-accepted. Logged loudly because this is the
        // one outcome the user must actually see.
        _logger.error(presentation.describe());
        return false;

      case HostKeyVerdict.unknown:
        final decide = onUnknownHostKey;
        if (decide == null) {
          _logger.warning(
            '${presentation.describe()} Refusing: no host key decision handler '
            'is wired, so an unknown host is never trusted automatically.',
          );
          return false;
        }
        final accepted = await decide(presentation);
        if (!accepted) {
          _logger.warning(
            'Host key for $host:$port was not accepted; connection refused.',
          );
          return false;
        }
        knownHosts.trust(
          KnownHostKey(
            host: host,
            port: port,
            keyType: keyType,
            fingerprint: fingerprint,
            trustedAt: clock.nowUtc(),
          ),
        );
        _logger.info(
          'Trusted new $keyType host key for $host:$port ($fingerprint).',
        );
        return true;
    }
  }
}
