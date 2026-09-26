import 'dart:io';

import 'package:karmashala_host/host_paths.dart' show HostPaths;
import 'package:karmashala_host/server_config.dart'
    show defaultServerDataDirectory;

import '../probe/probe_mode.dart';

/// The server's data folder — the one per user per machine: `~/.karmashala`
/// (`%USERPROFILE%\.karmashala` on Windows), or `KARMASHALA_DATA_DIR` when
/// set (a probe's own folder). The desktop app is a client of the server that
/// owns it: the database it opens (`karmashala.sqlite`, shared with the
/// server in WAL), `server.json`, the MCP handshake and session configs, and
/// verification artifacts all live here. What only the app keeps — logs,
/// keymap, recordings, window state — stays in [appSupportDirectory].
///
/// A probe without its own folder throws [ProbeDataDirectoryError], as
/// [resolveDataDirectory] does, and so does one pointed at the real folder.
///
/// Under `flutter test` it is refused unless `KARMASHALA_DATA_DIR` names a
/// folder: a test must never open, create or write the owner's real one.
Future<Directory> serverDataDirectory() => _resolved ??= () {
  final probe = ProbeMode.current;
  if (Platform.environment['FLUTTER_TEST'] == 'true' &&
      probe.dataDirectory == null) {
    return Future<Directory>.error(
      StateError(
        'the server data folder is not resolved under flutter test; a test '
        'passes its own temp folder',
      ),
    );
  }
  return resolveServerDataDirectory(probe: probe);
}();

Future<Directory>? _resolved;

/// [serverDataDirectory], with what it reads passed in: [environment] stands
/// for the real one in a test. Created owner-only when it is not there yet —
/// it holds every paired phone's key; the server makes it so again at start.
Future<Directory> resolveServerDataDirectory({
  required ProbeMode probe,
  Map<String, String>? environment,
}) async {
  final real = defaultServerDataDirectory(
    environment: environment ?? Platform.environment,
  );
  final dir = await resolveDataDirectory(
    probe: probe,
    platformDefault: () async => Directory(real),
  );
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
    await HostPaths(dir).restrictToCurrentUser();
  }
  return dir;
}
