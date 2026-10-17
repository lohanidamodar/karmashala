import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The words for a server that has no `containers.*` yet.
const kContainersNeedNewerServer =
    'This server is older than this app and cannot make containers. Update '
    'it to use them.';

/// **Containers, as the app asks for them** — the server checks hosts, creates,
/// starts, stops and deletes; this only sends the requests.
class ContainersClient {
  const ContainersClient(this._client);

  final DataClient _client;

  Future<R> _ask<R>(DataRequest<R> request) async {
    try {
      return (await _client.send(request)).value;
    } on DataRefused catch (refusal) {
      if (refusal.message.contains('no data request is called')) {
        throw const DataRefused.unavailable(kContainersNeedNewerServer);
      }
      rethrow;
    }
  }

  /// Each step and log line of a create the server is doing.
  Stream<ContainerProgress> get progress => _client.containerProgress;

  /// Whether [environmentId] can run a container. Never throws.
  Future<HostCheck> check(String environmentId) async {
    try {
      return await _ask(ContainerHostCheck(environmentId));
    } on DataRefused catch (refusal) {
      return HostCheck.unreachable(refusal.message);
    }
  }

  Future<SshHost> create({
    required String environmentId,
    required String machineId,
    required ContainerSpec spec,
  }) => _ask(
    ContainerCreate(
      environmentId: environmentId,
      machineId: machineId,
      spec: spec,
    ),
  );

  Future<void> cancel(String machineId) =>
      _ask(ContainerCreateCancel(machineId));

  Future<ContainerState> status(String hostId) => _ask(ContainerStatus(hostId));

  Future<ContainerState> power(String hostId, ContainerPowerAction action) =>
      _ask(ContainerPower(hostId, action));

  Future<void> delete(String hostId, {required bool withHome}) =>
      _ask(ContainerDelete(hostId, withHome: withHome));
}

final containersClientProvider = Provider<ContainersClient>(
  (ref) => ContainersClient(ref.watch(dataClientProvider)),
);
