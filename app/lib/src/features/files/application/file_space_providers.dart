/// Where a file browser gets the machine it is browsing. One space per
/// environment, built on demand and closed with the widget that asked: the SSH
/// connection underneath is pooled and is not this provider's to close.
library;

import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environments_controller.dart';
import '../../ssh/application/ssh_providers.dart';
import '../data/local_file_space.dart';
import '../data/sftp_file_space.dart';
import '../domain/file_space.dart';

/// The machines a file browser can show, in the order the environments list
/// holds them: this computer first, then distributions, then hosts.
final browsableEnvironmentsProvider = Provider<List<ExecutionEnvironment>>((
  ref,
) {
  return [
    for (final environment in ref.watch(environmentsControllerProvider))
      if (_isBrowsable(environment)) environment,
  ];
});

/// The space for [environmentId], or null when this build cannot browse that
/// environment — a WSL distribution with no name on the row, an SSH
/// environment whose host has been deleted.
final fileSpaceProvider = Provider.autoDispose.family<FileSpace?, String>((
  ref,
  environmentId,
) {
  final environment = ref
      .watch(environmentsControllerProvider)
      .where((e) => e.id == environmentId)
      .firstOrNull;
  if (environment == null) return null;
  final space = _spaceFor(ref, environment);
  if (space != null) ref.onDispose(space.close);
  return space;
});

bool _isBrowsable(ExecutionEnvironment environment) =>
    switch (environment.kind) {
      EnvironmentKind.windowsNative || EnvironmentKind.localPosix => true,
      EnvironmentKind.wsl => environment.wslDistribution != null,
      EnvironmentKind.ssh => environment.sshHostId != null,
    };

FileSpace? _spaceFor(Ref ref, ExecutionEnvironment environment) {
  final label = environmentLabel(environment) ?? environment.name;
  switch (environment.kind) {
    case EnvironmentKind.windowsNative:
    case EnvironmentKind.localPosix:
      return LocalFileSpace(environmentId: environment.id, label: label);
    case EnvironmentKind.wsl:
      final distribution = environment.wslDistribution;
      if (distribution == null) return null;
      return wslFileSpace(
        environmentId: environment.id,
        distribution: distribution,
        label: label,
      );
    case EnvironmentKind.ssh:
      final hostId = environment.sshHostId;
      if (hostId == null) return null;
      return SftpFileSpace(
        label: label,
        browser: RemoteFileBrowser(
          connection: ref.read(sshConnectionPoolProvider).forHostId(hostId),
          environmentId: environment.id,
        ),
      );
  }
}
