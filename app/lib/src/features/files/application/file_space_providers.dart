/// Which machines a file browser can show. Their files are the server's to
/// read (slice 3c): this lists the environments, and nothing here opens one.
library;

import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environments_controller.dart';

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

bool _isBrowsable(ExecutionEnvironment environment) =>
    switch (environment.kind) {
      EnvironmentKind.windowsNative || EnvironmentKind.localPosix => true,
      EnvironmentKind.wsl => environment.wslDistribution != null,
      EnvironmentKind.ssh => environment.sshHostId != null,
    };
