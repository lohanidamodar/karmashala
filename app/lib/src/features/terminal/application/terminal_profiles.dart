import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environments_controller.dart';
import '../data/terminals_client.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// The shells a terminal can open in: the server machine's own (its POSIX
/// shells, or PowerShell, Command Prompt and each WSL distribution on a
/// Windows server — slice 5a), then each SSH host, whose terminals the
/// server opens on the box (slice 5d).
final terminalProfilesProvider = Provider<List<TerminalProfile>>((ref) {
  final server = ref.watch(terminalServerProfilesProvider);
  final environments = ref.watch(environmentsControllerProvider);
  return [
    ...server,
    for (final environment in environments)
      if (environment.kind == EnvironmentKind.ssh &&
          (environment.sshHostId ?? '').isNotEmpty)
        TerminalProfile.ssh(
          environment.sshHostId!,
          hostName: environment.name,
        ),
  ];
});
