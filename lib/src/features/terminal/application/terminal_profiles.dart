import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../environments/application/environments_controller.dart';
import '../domain/terminal_profile.dart';

/// The shells this machine can open a terminal in. Host-aware, which it was
/// not: a Mac's settings page listed PowerShell and Command Prompt, and picking
/// either changed nothing.
final terminalProfilesProvider = Provider<List<TerminalProfile>>((ref) {
  final environments = ref.watch(environmentsControllerProvider);
  return terminalProfilesFor(
    environments,
    hostIsWindows: Platform.isWindows,
    loginShell: loginShellPath(),
    shells: Platform.isWindows ? const [] : installedShells(),
  );
});

/// The owner's login shell, when `$SHELL` names one by absolute path. Only an
/// absolute path is trusted: `$SHELL` is inherited, and a relative value would
/// resolve against a working directory this app never chose.
String? loginShellPath() {
  final shell = Platform.environment['SHELL']?.trim();
  if (shell == null || !shell.startsWith('/')) return null;
  return shell;
}

/// The shells listed in `/etc/shells` that actually exist — the system's own
/// answer to what can be a login shell, which is what `chsh` validates against.
/// Filtered by existence because the file outlives uninstalls; read
/// synchronously, since it is a few hundred bytes and cached for the run.
List<String> installedShells() {
  try {
    final file = File('/etc/shells');
    if (!file.existsSync()) return const [];
    final shells = <String>[];
    for (final line in file.readAsLinesSync()) {
      final path = line.trim();
      if (path.isEmpty || path.startsWith('#') || !path.startsWith('/')) {
        continue;
      }
      if (shells.contains(path)) continue;
      if (!File(path).existsSync()) continue;
      shells.add(path);
    }
    return shells;
  } on FileSystemException {
    // Not worth failing a settings page over; `terminalProfilesFor` falls back
    // to the login shell.
    return const [];
  }
}
