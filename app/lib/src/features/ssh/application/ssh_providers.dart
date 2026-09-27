import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
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

/// Reads a private key on this app's machine, from the local environment its
/// path is paired with — for this app's own pool only; the server reads the
/// keys of the connections it makes on its own machine.
final sshPrivateKeyReaderProvider = Provider<EnvironmentPrivateKeyReader>((
  ref,
) {
  final environments = ref.watch(environmentsDataProvider);
  return EnvironmentPrivateKeyReader(environmentOf: environments.getById);
});

/// **This app's own pool** of SSH connections, one per host — kept only for
/// what the app still dials itself: SSH terminal panes, deploying the server
/// on a box, the relay set-up and a phone's pairing there (a later slice moves
/// those). The server's agent work, checks, worktrees, scans and test
/// connections dial the server's own pool (slice 3a).
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
