import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/ssh_host.dart';
import 'ssh_providers.dart';

/// The saved remote hosts, and the execution environments they own.
///
/// Adding a host is what *creates* an SSH execution environment: unlike Windows
/// and WSL, remote hosts are configured rather than discovered, so there is no
/// probe that could find them. The two rows are written together so an
/// environment never dangles without the host that says how to reach it.
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

  /// Inserts or updates [host] together with its environment row.
  ///
  /// Any open connection to it is dropped first. An edited address, port, user
  /// or key must take effect on the next connection — a pooled session opened
  /// under the old settings would otherwise keep answering, and the user would
  /// be looking at a machine they thought they had stopped talking to.
  Future<SshHost> save(SshHost host) async {
    await ref.read(sshConnectionPoolProvider).evict(host.id);
    ref.read(sshHostDaoProvider).upsert(host);
    ref.read(executionEnvironmentDaoProvider).upsert(sshEnvironment(host));
    state = ref.read(sshHostDaoProvider).getAll();
    return host;
  }

  /// Removes a host, its environment, and any open connection to it.
  ///
  /// The trusted host key is deliberately kept: forgetting a machine's identity
  /// because its bookmark was deleted would turn a later re-add into a silent
  /// re-trust.
  Future<void> remove(String hostId) async {
    await ref.read(sshConnectionPoolProvider).evict(hostId);
    ref.read(executionEnvironmentDaoProvider).delete(sshEnvironmentId(hostId));
    ref.read(sshHostDaoProvider).delete(hostId);
    state = ref.read(sshHostDaoProvider).getAll();
  }
}

final sshHostsControllerProvider =
    NotifierProvider<SshHostsController, List<SshHost>>(SshHostsController.new);
