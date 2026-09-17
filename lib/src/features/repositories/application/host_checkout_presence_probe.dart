import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';

import '../../projects/application/wsl_path_existence.dart';

/// [CheckoutPresenceProbe] as the app asks it: a WSL checkout from **inside its
/// distribution**, over `wsl.exe`, and everything else as [local] does.
///
/// A stat over `\\wsl.localhost` could not tell a stopped distribution from a
/// deleted folder, blocked for seconds on one, and is what Windows on-access
/// antivirus scans (docs/windows-antivirus.md). Asked this way a stopped
/// distribution answers `unknown` — it is not started — and every checkout
/// asked about in one turn is one call.
class HostCheckoutPresenceProbe implements CheckoutPresenceProbe {
  const HostCheckoutPresenceProbe({
    required this.wsl,
    this.local = const LocalCheckoutPresenceProbe(),
  });

  final WslPathExistence wsl;
  final CheckoutPresenceProbe local;

  @override
  Future<CheckoutPresence> presenceOf(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  }) async {
    if (environment.kind != EnvironmentKind.wsl) {
      return local.presenceOf(
        directory,
        environment: environment,
        windows: windows,
      );
    }
    final distribution = environment.wslDistribution;
    if (directory.environmentId != environment.id ||
        distribution == null ||
        windows.kind != EnvironmentKind.windowsNative) {
      return CheckoutPresence.unknown;
    }
    // Fresh: what is decided here deletes a row, so a kept answer is no proof.
    return switch (await wsl.exists(
      distribution,
      directory.path,
      fresh: true,
    )) {
      true => CheckoutPresence.present,
      false => CheckoutPresence.absent,
      null => CheckoutPresence.unknown,
    };
  }
}
