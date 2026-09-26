import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/connection.dart';
import 'ssh_providers.dart';

/// The saved remote hosts and the environments they own — the server's,
/// followed as they change. Adding a host is what *creates* an SSH
/// environment: the server writes the two rows together.
class SshHostsController extends Notifier<List<SshHost>> {
  @override
  List<SshHost> build() {
    final data = ref.watch(sshHostsDataProvider);
    final hosts = data.getAll();
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return hosts;
  }

  /// Saves a new host and its `ssh:<id>` execution environment.
  Future<SshHost> add({
    required String name,
    required String host,
    required int port,
    required String username,
    required SshAuthMethod authMethod,
    EnvironmentPath? privateKey,
    String? defaultDirectory,
  }) {
    final id = ref.read(idGeneratorProvider).newId();
    final record = SshHost(
      id: id,
      name: name,
      host: host,
      port: port,
      username: username,
      authMethod: authMethod,
      privateKey: privateKey,
      defaultDirectory: defaultDirectory == null
          ? null
          : EnvironmentPath(
              environmentId: sshEnvironmentId(id),
              path: defaultDirectory,
            ),
      createdAt: ref.read(clockProvider).nowUtc(),
    );
    return save(record);
  }

  /// Saves [host] with its environment row at the server, dropping any open
  /// connection: a pooled session under the old settings would keep answering.
  /// Throws [DataRefused] for a host out of shape, in words to show.
  Future<SshHost> save(SshHost host) async {
    await ref.read(sshConnectionPoolProvider).evict(host.id);
    final saved = await ref.read(sshHostsDataProvider).put(host);
    state = ref.read(sshHostsDataProvider).getAll();
    return saved;
  }

  /// The projects that have to go before [hostId] can: its environment row is
  /// what they point at, and the store refuses to orphan them.
  Future<List<String>> projectsHolding(String hostId) => ref
      .read(workspaceDataProvider)
      .write(ProjectsUsingEnvironment(sshEnvironmentId(hostId)));

  /// Removes a host, its environment and any open connection. The trusted host
  /// key is kept: dropping it would make a later re-add a silent re-trust.
  ///
  /// Throws [SshHostInUse], and changes nothing, while projects still use it
  /// (the server refuses it too, whoever asks).
  Future<void> remove(String hostId) async {
    final holding = await projectsHolding(hostId);
    if (holding.isNotEmpty) throw SshHostInUse(holding);
    await ref.read(sshConnectionPoolProvider).evict(hostId);
    await ref.read(sshHostsDataProvider).delete(hostId);
    state = ref.read(sshHostsDataProvider).getAll();
  }
}

/// A host whose environment [projects] still use, named so the user can remove
/// them first.
class SshHostInUse implements Exception {
  const SshHostInUse(this.projects);

  final List<String> projects;

  @override
  String toString() => 'SshHostInUse: ${projects.join(', ')}';
}

final sshHostsControllerProvider =
    NotifierProvider<SshHostsController, List<SshHost>>(SshHostsController.new);
