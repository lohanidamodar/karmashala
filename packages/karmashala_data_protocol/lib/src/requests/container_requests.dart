part of '../data_request.dart';

// Linux containers as machines: the server checks a Docker host (an SSH host
// or a WSL distribution), creates a container there, saves it as an SSH host
// reached through that host, and starts, stops and deletes it. Progress of a
// create is told as `ContainerProgress`. Nothing here carries a key.

DataRequest<Object?>? _containerRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  ContainerHostCheck.name => ContainerHostCheck(args.string('environmentId')),
  ContainerCreate.name => ContainerCreate(
    environmentId: args.string('environmentId'),
    machineId: args.string('machineId'),
    spec: args.value('spec', containerSpecFromJson),
  ),
  ContainerCreateCancel.name => ContainerCreateCancel(args.string('machineId')),
  ContainerStatus.name => ContainerStatus(args.string('hostId')),
  ContainerPower.name => ContainerPower(
    args.string('hostId'),
    _named(ContainerPowerAction.values, args, 'action'),
  ),
  ContainerDelete.name => ContainerDelete(
    args.string('hostId'),
    withHome: args.boolean('withHome', orElse: false),
  ),
  _ => null,
};

/// Whether environment [environmentId] can run a container, and what it has.
final class ContainerHostCheck extends SshWorkRequest<HostCheck> {
  const ContainerHostCheck(this.environmentId);

  static const String name = 'containers.check';

  final String environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'environmentId': environmentId};

  @override
  Object? resultToJson(HostCheck result) => hostCheckToJson(result);

  @override
  HostCheck resultFromJson(Object? json) =>
      _decode(kind, () => hostCheckFromJson(_object(json, kind)));
}

/// Creates the container [spec] describes on [environmentId] and answers the
/// SSH host it is saved as, under [machineId] — the id its progress is told
/// with, chosen by the client so it can follow from the start.
final class ContainerCreate extends SshWorkRequest<SshHost> {
  const ContainerCreate({
    required this.environmentId,
    required this.machineId,
    required this.spec,
  });

  static const String name = 'containers.create';

  final String environmentId;
  final String machineId;
  final ContainerSpec spec;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environmentId': environmentId,
    'machineId': machineId,
    'spec': containerSpecToJson(spec),
  };

  @override
  Object? resultToJson(SshHost result) => sshHostToJson(result);

  @override
  SshHost resultFromJson(Object? json) =>
      _decode(kind, () => sshHostFromJson(_object(json, kind)));
}

/// Stops the create under way for [machineId] and removes what it made; the
/// create then answers refused. Acknowledged even when nothing is under way.
final class ContainerCreateCancel extends SshWorkRequest<DataAck> {
  const ContainerCreateCancel(this.machineId);

  static const String name = 'containers.cancelCreate';

  final String machineId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'machineId': machineId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Where container machine [hostId] stands, as `docker inspect` says.
final class ContainerStatus extends SshWorkRequest<ContainerState> {
  const ContainerStatus(this.hostId);

  static const String name = 'containers.status';

  final String hostId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'hostId': hostId};

  @override
  Object? resultToJson(ContainerState result) => result.name;

  @override
  ContainerState resultFromJson(Object? json) => _decode(
    kind,
    () => ContainerState.values.firstWhere(
      (state) => state.name == json,
      orElse: () => ContainerState.unknown,
    ),
  );
}

enum ContainerPowerAction { start, stop }

/// Starts or stops container machine [hostId]; answers where it then stands.
final class ContainerPower extends SshWorkRequest<ContainerState> {
  const ContainerPower(this.hostId, this.action);

  static const String name = 'containers.power';

  final String hostId;
  final ContainerPowerAction action;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': hostId,
    'action': action.name,
  };

  @override
  Object? resultToJson(ContainerState result) => result.name;

  @override
  ContainerState resultFromJson(Object? json) => _decode(
    kind,
    () => ContainerState.values.firstWhere(
      (state) => state.name == json,
      orElse: () => ContainerState.unknown,
    ),
  );
}

/// Deletes container machine [hostId]: the container (only one Karmashala
/// made), its home volume when [withHome], the saved host and its pinned key.
/// Refused while a project uses it.
final class ContainerDelete extends SshWorkRequest<DataAck> {
  const ContainerDelete(this.hostId, {this.withHome = false});

  static const String name = 'containers.delete';

  final String hostId;
  final bool withHome;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': hostId,
    'withHome': withHome,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
