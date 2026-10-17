import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environments_controller.dart';
import '../../ssh/application/ssh_hosts_controller.dart';
import '../data/containers_client.dart';

/// How many of a create's latest log lines a row keeps.
const kCreationLogLines = 6;

/// A container being created, as its row shows it.
class ContainerCreation {
  const ContainerCreation({
    required this.machineId,
    required this.name,
    required this.hostName,
    required this.step,
    this.log = const [],
    this.error,
  });

  final String machineId;
  final String name;

  /// The host it is being made on, by name.
  final String hostName;
  final ContainerStep step;

  /// Its latest lines, oldest first.
  final List<String> log;

  /// Why it failed; the row stays until dismissed.
  final String? error;

  bool get failed => error != null;

  ContainerCreation copyWith({
    ContainerStep? step,
    List<String>? log,
    String? error,
  }) => ContainerCreation(
    machineId: machineId,
    name: name,
    hostName: hostName,
    step: step ?? this.step,
    log: log ?? this.log,
    error: error ?? this.error,
  );
}

/// The steps a row counts, in order: "step 3 of 6".
const kCreationSteps = [
  ContainerStep.checking,
  ContainerStep.pulling,
  ContainerStep.starting,
  ContainerStep.settingUp,
  ContainerStep.connecting,
  ContainerStep.detecting,
];

/// The creates under way, by machine id, each following the server's
/// progress. A finished one leaves the list: the machine is then a saved host.
class ContainerCreationsController
    extends Notifier<Map<String, ContainerCreation>> {
  StreamSubscription<ContainerProgress>? _progress;

  @override
  Map<String, ContainerCreation> build() {
    final client = ref.watch(containersClientProvider);
    _progress = client.progress.listen(_onProgress);
    ref.onDispose(() => _progress?.cancel());
    return const {};
  }

  void _onProgress(ContainerProgress progress) {
    final creation = state[progress.machineId];
    if (creation == null || creation.failed) return;
    final line = progress.line;
    final log = line == null || line.trim().isEmpty
        ? creation.log
        : [
            ...creation.log,
            line,
          ].reversed.take(kCreationLogLines).toList().reversed.toList();
    state = {
      ...state,
      progress.machineId: creation.copyWith(step: progress.step, log: log),
    };
  }

  /// Starts creating [spec] on [host]; the machine id it is followed by.
  String start(ContainerHostChoice host, ContainerSpec spec) {
    final machineId = ref.read(idGeneratorProvider).newId();
    state = {
      ...state,
      machineId: ContainerCreation(
        machineId: machineId,
        name: spec.name,
        hostName: host.name,
        step: ContainerStep.checking,
      ),
    };
    unawaited(_create(host.id, machineId, spec));
    return machineId;
  }

  Future<void> _create(
    String environmentId,
    String machineId,
    ContainerSpec spec,
  ) async {
    try {
      await ref
          .read(containersClientProvider)
          .create(
            environmentId: environmentId,
            machineId: machineId,
            spec: spec,
          );
      if (!ref.mounted) return;
      state = {...state}..remove(machineId);
    } on DataRefused catch (refusal) {
      _fail(machineId, refusal.message);
    } on Object catch (error) {
      _fail(machineId, '$error');
    }
  }

  void _fail(String machineId, String why) {
    if (!ref.mounted) return;
    final creation = state[machineId];
    if (creation == null) return;
    state = {
      ...state,
      machineId: creation.copyWith(step: ContainerStep.failed, error: why),
    };
  }

  /// Stops a create under way; the server removes what it made.
  Future<void> cancel(String machineId) =>
      ref.read(containersClientProvider).cancel(machineId);

  /// Forgets a failed create's row.
  void dismiss(String machineId) => state = {...state}..remove(machineId);
}

final containerCreationsControllerProvider =
    NotifierProvider<
      ContainerCreationsController,
      Map<String, ContainerCreation>
    >(ContainerCreationsController.new);

/// A host a container could be made on, as the form lists it.
class ContainerHostChoice {
  const ContainerHostChoice({
    required this.id,
    required this.name,
    required this.isWsl,
  });

  /// Its environment id: `ssh:<id>` or `wsl:<distribution>`.
  final String id;
  final String name;
  final bool isWsl;
}

/// Where a container can be made: WSL distributions and SSH hosts that are
/// not containers themselves.
final containerHostsProvider = Provider<List<ContainerHostChoice>>((ref) {
  final hosts = {
    for (final host in ref.watch(sshHostsControllerProvider)) host.id: host,
  };
  return [
    for (final environment in ref.watch(environmentsControllerProvider))
      if (environment.kind == EnvironmentKind.wsl ||
          (environment.kind == EnvironmentKind.ssh &&
              hosts[environment.sshHostId]?.container == null &&
              hosts.containsKey(environment.sshHostId)))
        ContainerHostChoice(
          id: environment.id,
          name: environment.name,
          isWsl: environment.kind == EnvironmentKind.wsl,
        ),
  ];
});

/// The name of environment [environmentId], or null when it is not known.
final environmentNameProvider = Provider.family<String?, String>(
  (ref, environmentId) => ref
      .watch(environmentsControllerProvider)
      .where((e) => e.id == environmentId)
      .firstOrNull
      ?.name,
);

/// The saved hosts that are containers, oldest first.
final containerMachinesProvider = Provider<List<SshHost>>(
  (ref) => [
    for (final host in ref.watch(sshHostsControllerProvider))
      if (host.container != null) host,
  ],
);

/// Whether one environment can run a container; re-read by invalidating.
final containerHostCheckProvider = FutureProvider.autoDispose
    .family<HostCheck, String>(
      (ref, environmentId) =>
          ref.watch(containersClientProvider).check(environmentId),
    );

/// Where one container machine stands; re-read by invalidating.
final containerStateProvider = FutureProvider.autoDispose
    .family<ContainerState, String>(
      (ref, hostId) => ref.watch(containersClientProvider).status(hostId),
    );

/// Start, stop and delete for a container's row, each re-reading its state.
class ContainerActions {
  const ContainerActions(this._ref);

  final Ref _ref;

  Future<ContainerState> power(
    String hostId,
    ContainerPowerAction action,
  ) async {
    try {
      return await _ref.read(containersClientProvider).power(hostId, action);
    } finally {
      _ref.invalidate(containerStateProvider(hostId));
    }
  }

  Future<void> delete(String hostId, {required bool withHome}) =>
      _ref.read(containersClientProvider).delete(hostId, withHome: withHome);

  /// Checks [environmentId] again.
  void recheck(String environmentId) =>
      _ref.invalidate(containerHostCheckProvider(environmentId));
}

final containerActionsProvider = Provider<ContainerActions>(
  ContainerActions.new,
);
