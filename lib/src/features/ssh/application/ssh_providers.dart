import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../data/known_host_dao.dart';
import '../data/ssh_connection.dart';
import '../data/ssh_connection_pool.dart';
import '../data/ssh_host_dao.dart';
import '../data/ssh_host_key_verifier.dart';

/// Persistence for saved SSH hosts.
final sshHostDaoProvider = Provider<SshHostDao>(
  (ref) => SshHostDao(ref.watch(databaseProvider)),
);

/// Persistence for trusted host keys (our `known_hosts`).
final knownHostDaoProvider = Provider<KnownHostDao>(
  (ref) => KnownHostDao(ref.watch(databaseProvider)),
);

/// How an unknown host key is decided.
///
/// Null by default, and that default is the safe one: with nothing wired, an
/// unrecognised host is **refused** rather than trusted. The UI overrides this
/// with a handler that shows the fingerprint and waits for the user.
final hostKeyTrustDecisionProvider = Provider<HostKeyTrustDecision?>(
  (ref) => null,
);

/// How a password is obtained, for hosts that only allow password auth.
/// Null means such a host simply cannot connect — nothing is guessed or stored.
final sshPasswordPromptProvider = Provider<SshSecretPrompt?>((ref) => null);

/// How a private key passphrase is obtained. Same rule: never stored.
final sshPassphrasePromptProvider = Provider<SshSecretPrompt?>((ref) => null);

/// The shared pool of SSH connections, one per host.
final sshConnectionPoolProvider = Provider<SshConnectionPool>((ref) {
  final pool = SshConnectionPool(
    hosts: ref.watch(sshHostDaoProvider),
    knownHosts: ref.watch(knownHostDaoProvider),
    onUnknownHostKey: ref.watch(hostKeyTrustDecisionProvider),
    passwordPrompt: ref.watch(sshPasswordPromptProvider),
    passphrasePrompt: ref.watch(sshPassphrasePromptProvider),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(pool.closeAll);
  return pool;
});
