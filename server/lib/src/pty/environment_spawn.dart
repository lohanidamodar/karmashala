import 'package:agent_cli/process.dart';

import 'pty.dart';

/// What the server starts to run [argv] in [directory] of [environment]:
/// this machine's own (or null) directly, a WSL distribution through
/// `wsl.exe -d <distro> --cd <dir> -- …` (slice 5a — only a Windows server
/// reaches one; callers ask `DaemonCheckoutFacts.isHere` first).
///
/// A WSL launch has no host working directory — `--cd` sets the Linux one,
/// which Windows' `CreateProcess` would refuse — and its [variables] cross
/// into the distribution by name in `WSLENV` (`/u`, never `/p`, which would
/// rewrite a path-like value), never as words of its command line.
/// [removed] applies to what this server hands the child: for WSL that is
/// `wsl.exe` itself, and a distribution's own profile is out of reach.
PtySpawnRequest spawnRequestIn(
  ExecutionEnvironment? environment, {
  required List<String> argv,
  String? directory,
  Map<String, String> variables = const {},
  Set<String> removed = const {},
  int columns = 120,
  int rows = 40,
}) {
  if (environment == null || environment.kind != EnvironmentKind.wsl) {
    return PtySpawnRequest(
      argv: argv,
      workingDirectory: directory,
      environment: {'TERM': 'xterm-256color', ...variables},
      removedEnvironment: removed,
      columns: columns,
      rows: rows,
    );
  }
  return PtySpawnRequest(
    argv: [
      'wsl.exe',
      '-d',
      environment.wslDistribution ?? '',
      if (directory != null && directory.isNotEmpty) ...['--cd', directory],
      '--',
      ...argv,
    ],
    environment: {
      'TERM': 'xterm-256color',
      ...variables,
      if (variables.isNotEmpty)
        'WSLENV': variables.keys.map((name) => '$name/u').join(':'),
    },
    removedEnvironment: removed,
    columns: columns,
    rows: rows,
  );
}
