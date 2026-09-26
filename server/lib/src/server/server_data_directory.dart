import 'dart:io';

import 'package:path/path.dart' as p;

/// The server's data directory when no `--data-dir` names another — the one
/// folder per user per machine: `~/.karmashala` (`%USERPROFILE%\.karmashala`
/// on Windows). Its store, `server.json`, the MCP handshake and session
/// configs, and the files phones send.
///
/// The desktop app opens its database here and starts `serve` with no
/// `--data-dir`; the SSH deployer and the installers use it too, so a machine
/// set up any of those ways is one server with one set of pairings. The
/// socket, lock and sessions go where they always go (`HostPaths.resolve` —
/// the runtime dir when there is one, else this same directory).
///
/// [environment] is always passed — never read here — so nothing in this
/// library lands in the real home without its caller saying so.
String defaultServerDataDirectory({required Map<String, String> environment}) {
  final env = environment;
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
