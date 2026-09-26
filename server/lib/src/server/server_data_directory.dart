import 'dart:io';

import 'package:path/path.dart' as p;

/// Where `serve --standalone` keeps its store and `server.json` when no
/// `--data-dir` names another: `~/.karmashala` (`%USERPROFILE%\.karmashala`
/// on Windows).
///
/// The same directory the SSH deployer starts a box's host with, on purpose:
/// a box set up by hand and one set up from the desktop are one server with
/// one set of pairings, whichever way it was installed. The socket, lock and
/// sessions go where they always go (`HostPaths.resolve` — the runtime dir
/// when there is one, else this same directory).
String defaultServerDataDirectory({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final home = Platform.isWindows
      ? (env['USERPROFILE'] ?? env['HOME'])
      : (env['HOME'] ?? env['USERPROFILE']);
  if (home == null || home.isEmpty) {
    throw StateError(
      'neither HOME nor USERPROFILE is set, so there is no home to keep the '
      'server in — pass --data-dir=<dir>',
    );
  }
  return p.join(home, '.karmashala');
}
