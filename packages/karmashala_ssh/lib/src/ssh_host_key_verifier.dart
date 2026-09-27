import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'ssh_host_key.dart';

/// Asked when a host presents a key we have never seen; `true` trusts it from
/// now on. Only called for an unknown key — a changed one is never offered.
typedef HostKeyTrustDecision =
    FutureOr<bool> Function(HostKeyPresentation presentation);

/// Decides whether to accept a presented host key, with OpenSSH's policy: known
/// accepts, unknown asks (and refuses with no handler), changed always refuses.
class SshHostKeyVerifier {
  SshHostKeyVerifier({
    required this.knownHosts,
    required this.host,
    required this.port,
    required this.clock,
    this.onUnknownHostKey,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('ssh.hostkey');

  final KnownHostStore knownHosts;
  final String host;
  final int port;
  final Clock clock;
  final HostKeyTrustDecision? onUnknownHostKey;
  final AppLogger _logger;

  /// The most recent presentation, kept so a refused connection can explain
  /// itself precisely instead of surfacing a bare handshake error.
  HostKeyPresentation? lastPresentation;

  /// Why the last unknown key could not even be put to a person, when the
  /// decision threw rather than answered — the words a refusal carries.
  Object? lastRefusal;

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
    lastRefusal = null;

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
        final bool accepted;
        try {
          accepted = await decide(presentation);
        } on Object catch (refusal) {
          // Nobody could be asked — the decision says why, in its own words.
          lastRefusal = refusal;
          _logger.warning('Host key for $host:$port not asked: $refusal');
          return false;
        }
        if (!accepted) {
          _logger.warning(
            'Host key for $host:$port was not accepted; connection refused.',
          );
          return false;
        }
        final recorded = await knownHosts.trust(
          KnownHostKey(
            host: host,
            port: port,
            keyType: keyType,
            fingerprint: fingerprint,
            trustedAt: clock.nowUtc(),
          ),
        );
        if (!recorded) {
          // Another key was trusted for this host meanwhile: the store keeps
          // the first, and this connection is refused like a changed key.
          _logger.error(
            'Host key for $host:$port was not recorded as trusted; '
            'connection refused.',
          );
          return false;
        }
        _logger.info(
          'Trusted new $keyType host key for $host:$port ($fingerprint).',
        );
        return true;
    }
  }
}
