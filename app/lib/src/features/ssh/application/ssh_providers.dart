import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../data/environment_key_reader.dart';
import 'package:karmashala_ssh/connection.dart';
import '../data/ssh_hosts_data.dart';
import 'ssh_prompt_controller.dart';

export '../data/ssh_hosts_data.dart'
    show
        KnownHostsData,
        SshHostsData,
        knownHostsDataProvider,
        sshHostsDataProvider;

/// How an unknown host key is decided: by asking the user through
/// [SshPromptController], which refuses outright when no prompt UI is mounted.
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

/// Reads a private key from the local environment its path is paired with.
final sshPrivateKeyReaderProvider = Provider<EnvironmentPrivateKeyReader>(
  (ref) => EnvironmentPrivateKeyReader(
    environments: ref.watch(environmentsDataProvider),
  ),
);

/// The shared pool of SSH connections, one per host.
final sshConnectionPoolProvider = Provider<SshConnectionPool>((ref) {
  final pool = SshConnectionPool(
    hosts: ref.watch(sshHostsDataProvider),
    knownHosts: ref.watch(knownHostsDataProvider),
    onUnknownHostKey: ref.watch(hostKeyTrustDecisionProvider),
    passwordPrompt: ref.watch(sshPasswordPromptProvider),
    passphrasePrompt: ref.watch(sshPassphrasePromptProvider),
    keyReader: ref.watch(sshPrivateKeyReaderProvider).read,
    clock: ref.watch(clockProvider),
  );
  // `onDispose` takes a callback, not a future, so this close is started and
  // dropped; the lifecycle owner awaits its own inside the shutdown budget.
  ref.onDispose(pool.closeAll);
  return pool;
});
