import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../environments/application/environments_controller.dart';
import '../domain/terminal_profile.dart';

/// The shells this machine can open a terminal in.
///
/// Host-aware, which it was not: every host was offered PowerShell and Command
/// Prompt, so a Mac's settings page listed two shells it does not have, and
/// picking either changed nothing — the launch path ignores the profile off
/// Windows and opens `$SHELL` regardless.
final terminalProfilesProvider = Provider<List<TerminalProfile>>((ref) {
  final environments = ref.watch(environmentsControllerProvider);
  return terminalProfilesFor(
    environments,
    hostIsWindows: Platform.isWindows,
    loginShell: loginShellPath(),
    shells: Platform.isWindows ? const [] : installedShells(),
  );
});

/// The owner's login shell, when `$SHELL` names one by absolute path.
///
/// Only an absolute path is trusted: `$SHELL` is inherited from whatever
/// launched the app, and a relative value would be resolved against a working
/// directory this app never chose.
String? loginShellPath() {
  final shell = Platform.environment['SHELL']?.trim();
  if (shell == null || !shell.startsWith('/')) return null;
  return shell;
}

/// The shells listed in `/etc/shells` that actually exist.
///
/// `/etc/shells` is the system's own answer to "what can be a login shell here"
/// — it is what `chsh` validates against — so it is the right list to offer
/// rather than probing a hardcoded set of paths. Entries are filtered by
/// existence because the file outlives uninstalls.
///
/// Read synchronously and once: it is a few hundred bytes on local disk, and
/// the provider above caches the result for the run.
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
    // An unreadable /etc/shells is not worth failing a settings page over;
    // `terminalProfilesFor` falls back to the login shell.
    return const [];
  }
}
