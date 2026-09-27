import 'dart:async';

import 'ssh_host.dart';
import 'ssh_host_key_verifier.dart';

/// **The prompts contract**: what a connection cannot decide alone — an
/// unknown host key, a password, a private key's passphrase — asked of
/// whoever owns the connection. The transport never decides these itself;
/// the Karmashala server implements this by putting each question to a
/// person through its windows (`SshPrompts`), and a test answers directly.
abstract interface class SshAsker {
  /// How an unknown key presented by [host] is decided. A changed key is
  /// never offered: the verifier refuses it outright.
  HostKeyTrustDecision hostKeyDecisionFor(SshHost host);

  /// [host]'s password, or null when nobody gave one.
  FutureOr<String?> password(SshHost host);

  /// The passphrase of [host]'s private key, or null when nobody gave one.
  FutureOr<String?> passphrase(SshHost host);
}
