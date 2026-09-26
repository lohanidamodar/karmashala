import 'dart:convert';
import 'dart:io';

import 'package:karmashala_remote/remote.dart' show scrubRelayLog;
import 'package:path/path.dart' as p;

import '../serve/host_paths.dart';
import '../serve/serve_command.dart' show dataDirectoryOf;
import 'server_config.dart';
import 'server_data_directory.dart';

/// `karmashala_host init [--data-dir=<dir>] [--force] [config flags…]`:
/// writes the server's `server.json` — owner-only from its first
/// byte, since it can hold the relay token — from the same flags `serve`
/// takes (`--name`, `--bind`, `--companion-port`, `--beacon`, `--relay`,
/// `--relay-token`, `--extra-relay`, `--no-notes`, `--mcp-port`,
/// `--no-companion`). Refuses to replace a file that is there without
/// `--force`. What the installers run, so a hand-written file and theirs are
/// checked by the same rules.
///
/// Without `--data-dir`, [environment] names the home; with neither the call
/// is a programming error ([ArgumentError]): the library never falls back to
/// the real home.
Future<int> runInit(
  List<String> args, {
  Map<String, String>? environment,
  IOSink? out,
  IOSink? err,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final String dataDirectory;
  try {
    final named = dataDirectoryOf(args);
    if (named == null && environment == null) {
      throw ArgumentError(
        'init: pass --data-dir=<dir> or the environment to find the home in',
      );
    }
    dataDirectory =
        named ?? defaultServerDataDirectory(environment: environment!);
  } on StateError catch (error) {
    errSink.writeln('karmashala_host init: ${error.message}');
    return 2;
  }
  final ServerConfig config;
  try {
    config = ServerConfig.fromFlags(args);
  } on ServerConfigError catch (error) {
    errSink.writeln('karmashala_host init: $error');
    return 2;
  }
  final path = p.join(dataDirectory, kServerConfigFileName);
  if (File(path).existsSync() && !args.contains('--force')) {
    errSink.writeln(
      'karmashala_host init: $path is already there; pass --force to replace '
      'it',
    );
    return 3;
  }
  final directory = Directory(dataDirectory);
  if (!directory.existsSync()) directory.createSync(recursive: true);
  final refused = await HostPaths(directory).restrictToCurrentUser();
  if (refused != null) {
    errSink.writeln('karmashala_host init: $refused');
    return 6;
  }
  await config.write(dataDirectory);
  sink
    ..writeln('wrote $path')
    ..writeln(
      scrubRelayLog(
        const JsonEncoder.withIndent('  ').convert(
          ServerConfig(
            name: config.name,
            companionEnabled: config.companionEnabled,
            bind: config.bind,
            companionPort: config.companionPort,
            beacon: config.beacon,
            relay: config.relay,
            relayToken: config.relayToken == null ? null : '…',
            relayEnabled: config.relayEnabled,
            extraRelays: config.extraRelays,
            notes: config.notes,
            mcpPort: config.mcpPort,
          ).toJson(),
        ),
      ),
    );
  return 0;
}
