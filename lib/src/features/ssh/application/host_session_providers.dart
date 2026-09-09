import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../data/host_binaries.dart';
import '../data/host_session_access.dart';
import '../domain/ssh_host.dart';
import 'ssh_providers.dart';

/// Where the cross-compiled host binaries are found on this machine.
final hostBinarySourceProvider = Provider<HostBinarySource>(
  (ref) => DirectoryHostBinaries.standard(),
);

/// One [HostSessionAccess] per saved host, for the life of the app.
///
/// Kept here rather than built per pane because deploying is an upload and a
/// handshake: doing it for every tab on a busy machine would cost a channel and
/// a round trip each time.
final hostSessionAccessRegistryProvider = Provider<HostSessionAccessRegistry>((ref) {
  final registry = HostSessionAccessRegistry(
    binaries: ref.watch(hostBinarySourceProvider),
    connectionFor: (hostId) => ref.read(sshConnectionPoolProvider).forHostId(hostId),
  );
  ref.onDispose(registry.dispose);
  return registry;
});

/// How a pane gets at a machine's session host, as one overridable function.
///
/// A provider rather than a call, for the same reason
/// `terminalInstanceFactoryProvider` is one: a test wants to open a real SSH
/// pane against a host that answers, or one that refuses, without an sshd.
typedef HostSessionAccessLookup = HostSessionAccess? Function(SshHost host);

final hostSessionAccessLookupProvider = Provider<HostSessionAccessLookup>(
  (ref) => (host) => _hostSessionAccessFor(ref, host),
);

/// The session host for [host], or null when this app cannot reach SSH at all.
///
/// Reachability is asked of [ExecutionEnvironmentResolver] rather than answered
/// again here: a container composed without a connection pool must read the same
/// way everywhere, and the resolver is the one place that says so. Only
/// [EnvironmentRefusal.sshUnavailable] blocks — a host row that no environment
/// names is unusual, not unreachable, and refusing on it would take the host
/// path away from a machine that works.
HostSessionAccess? _hostSessionAccessFor(Ref ref, SshHost host) {
  // The host binaries only exist on a desktop build; a companion has no
  // filesystem to find them in and no business deploying anything.
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return null;

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
