import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/probe/probe_mode.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_ssh/connection.dart';
import 'ssh_providers.dart';

/// Where the cross-compiled host binaries are found on this machine.
final hostBinarySourceProvider = Provider<HostBinarySource>(
  (ref) => DirectoryHostBinaries.standard(),
);

/// One [HostSessionAccess] per saved host, for the life of the app: deploying
/// is an upload and a handshake, too dear to repeat for every tab.
final hostSessionAccessRegistryProvider = Provider<HostSessionAccessRegistry>((
  ref,
) {
  final registry = HostSessionAccessRegistry(
    binaries: ref.watch(hostBinarySourceProvider),
    connectionFor: (hostId) =>
        ref.read(sshConnectionPoolProvider).forHostId(hostId),
  );
  ref.onDispose(registry.dispose);
  return registry;
});

/// How a pane gets at a machine's session host — a provider, so a test can open
/// a real SSH pane against a host that answers, or refuses, without an sshd.
typedef HostSessionAccessLookup = HostSessionAccess? Function(SshHost host);

final hostSessionAccessLookupProvider = Provider<HostSessionAccessLookup>(
  (ref) =>
      (host) => _hostSessionAccessFor(ref, host),
);

/// The session host for [host], or null when this app cannot reach SSH. Only
/// [EnvironmentRefusal.sshUnavailable] blocks; an unnamed environment does not.
HostSessionAccess? _hostSessionAccessFor(Ref ref, SshHost host) {
  // The host binaries only exist on a desktop build; a companion has no
  // filesystem to find them in and no business deploying anything.
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    return null;
  }
  // A machine's session host is per user there, and the owner's sessions are
  // in it: a probe that used it could list, end or take over any of them. So a
  // probe's SSH panes take the tmux path instead (§23).
  if (ref.read(probeModeProvider).enabled) return null;

  final environments = ref.read(executionEnvironmentDaoProvider).getAll();
  final match = environments
      .where((e) => e.kind == EnvironmentKind.ssh && e.sshHostId == host.id)
      .firstOrNull;
  if (match != null) {
    final resolution = ref.read(environmentResolverProvider).resolve(match.id);
    if (resolution.refusal == EnvironmentRefusal.sshUnavailable) return null;
  }
  return ref.read(hostSessionAccessRegistryProvider).forHost(host);
}

/// Everything needed to invite a phone to one machine: the address this desktop
/// connected with, the companion port, and the host already running there.
///
/// Built per host and never cached — a port that was open an hour ago is not a
/// port that is open now, and this answers by dialling (§19).
final sshCompanionSetupProvider =
    FutureProvider.family<SshCompanionSetup, SshHost>((ref, host) async {
      final access = ref.read(hostSessionAccessRegistryProvider).forHost(host);
      // The pane's own reading, so a pairing lands on the host the sessions are
      // in rather than a second one at a path nobody is watching.
      final deployment = await access.deployment();
      final remotePath = deployment.remotePath;
      if (remotePath == null) {
        throw HostDeployFailure(hostName: host.name, deployment: deployment);
      }
      return SshCompanionSetup(
        host: host,
        target: SshHostDeployTarget(
          ref.read(sshConnectionPoolProvider).forHostId(host.id),
        ),
        remotePath: remotePath,
      );
      // Never retried on its own: Riverpod retries an `Exception` ten times,
      // and each would be another deploy at somebody's machine while the
      // dialog spins. The dialog has a button for it.
    }, retry: (_, _) => null);
