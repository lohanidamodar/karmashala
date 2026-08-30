import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../data/known_host_dao.dart';
import '../data/ssh_connection.dart';
import '../data/ssh_connection_pool.dart';
import '../data/ssh_host_dao.dart';
import '../data/ssh_host_key_verifier.dart';
import 'ssh_prompt_controller.dart';

/// Persistence for saved SSH hosts.
final sshHostDaoProvider = Provider<SshHostDao>(
  (ref) => SshHostDao(ref.watch(databaseProvider)),
);

/// Persistence for trusted host keys (our `known_hosts`).
final knownHostDaoProvider = Provider<KnownHostDao>(
  (ref) => KnownHostDao(ref.watch(databaseProvider)),
);

/// How an unknown host key is decided: by asking the user, through
/// [SshPromptController].
///
/// The safe default Loop 37 shipped is preserved rather than replaced. The
/// controller refuses outright whenever no prompt UI is mounted, so an
/// unattended run still never trusts a new host — but when a window *is* open,
/// the fingerprint is put in front of the user instead of the connection dying
/// with nobody able to say yes.
final hostKeyTrustDecisionProvider = Provider<HostKeyTrustDecision?>(
  (ref) =>
      (presentation) => ref
          .read(sshPromptControllerProvider.notifier)
          .askHostKey(presentation),
);

/// How a password is obtained, for hosts that only allow password auth. Asked
/// per connection and held in memory only — `ssh_hosts` has no column for it.
final sshPasswordPromptProvider = Provider<SshSecretPrompt?>(
  (ref) =>
      (host) => ref
          .read(sshPromptControllerProvider.notifier)
          .askSecret(host, SshSecretKind.password),
);

/// How a private key passphrase is obtained. Same rule: never stored.
final sshPassphrasePromptProvider = Provider<SshSecretPrompt?>(
  (ref) =>
      (host) => ref
          .read(sshPromptControllerProvider.notifier)
          .askSecret(host, SshSecretKind.passphrase),
);

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
