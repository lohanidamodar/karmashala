import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../projects/application/project_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/connection.dart';
import 'ssh_providers.dart';

/// The saved remote hosts and the environments they own. Adding a host is what
/// *creates* an SSH environment — the two rows are written together.
class SshHostsController extends Notifier<List<SshHost>> {
  @override
  List<SshHost> build() => ref.watch(sshHostDaoProvider).getAll();

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

  /// Inserts or updates [host] with its environment row, dropping any open
  /// connection: a pooled session under the old settings would keep answering.
  Future<SshHost> save(SshHost host) async {
    await ref.read(sshConnectionPoolProvider).evict(host.id);
    ref.read(sshHostDaoProvider).upsert(host);
    ref.read(executionEnvironmentDaoProvider).upsert(sshEnvironment(host));
    // The environments list is built from the same table: an environment you
    // have just created but cannot see is not created, as far as the user goes.
    ref.invalidate(environmentsControllerProvider);
    state = ref.read(sshHostDaoProvider).getAll();
    return host;
  }

  /// The projects that have to go before [hostId] can: its environment row is
  /// what they point at, and the store refuses to orphan them.
  List<String> projectsHolding(String hostId) => ref
      .read(projectDaoProvider)
      .namesUsingEnvironment(sshEnvironmentId(hostId));

  /// Removes a host, its environment and any open connection. The trusted host
  /// key is kept: dropping it would make a later re-add a silent re-trust.
  ///
  /// Throws [SshHostInUse], and changes nothing, while projects still use it.
  Future<void> remove(String hostId) async {
    final holding = projectsHolding(hostId);
    if (holding.isNotEmpty) throw SshHostInUse(holding);
    await ref.read(sshConnectionPoolProvider).evict(hostId);
    ref.read(executionEnvironmentDaoProvider).delete(sshEnvironmentId(hostId));
    ref.read(sshHostDaoProvider).delete(hostId);
    ref.invalidate(environmentsControllerProvider);
    state = ref.read(sshHostDaoProvider).getAll();
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
