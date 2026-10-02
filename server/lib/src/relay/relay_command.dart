import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';

const relayUsage =
    '''
karmashala_host relay — a relay for one desktop, on this machine.

Required:
  --port=<n>            where to listen (0 asks the OS for a free one)
  --token-file=<path>   the access token; minted here, owner-only, if absent
  --pid-file=<path>     where this process writes its pid, removed when it stops

Optional:
  --address=<host>      the interface to bind (default 0.0.0.0)
  --max-rendezvous=<n>  rendezvous held at once (default $kBoxRelayMaxRendezvous)
''';

/// One desktop and its phones, a listening window each: nowhere near the
/// shared relay's ten thousand, so a found token buys very little.
const int kBoxRelayMaxRendezvous = 256;

/// A relay that is up. [stop] closes it and removes the pid file.
class StartedRelay {
  StartedRelay._(this.server, this._pidFile);

  final RelayServer server;
  final File _pidFile;

  int get port => server.port;

  Future<void> stop() async {
    await server.close();
    try {
      if (_pidFile.existsSync()) _pidFile.deleteSync();
    } on FileSystemException {
      // A pid file that will not go is stale the moment this exits; whoever
      // reads it checks the process, not the file.
    }
  }
}

/// Parses [args], prepares the token and binds. The relay comes back running,
/// or null with the exit code to leave with.
Future<({StartedRelay? relay, int exitCode})> startRelay(
  List<String> args, {
  required IOSink out,
  required IOSink err,
}) async {
  if (args.contains('-h') || args.contains('--help')) {
    out.write(relayUsage);
    return (relay: null, exitCode: 0);
  }
  final options = _RelayArgs.tryParse(args);
  if (options == null) {
    err.write(relayUsage);
    return (relay: null, exitCode: 2);
  }

  final String token;
  try {
    token = await _readOrMintToken(File(options.tokenFile));
  } on _TokenFileException catch (error) {
    err.writeln('karmashala_host: refusing to relay — ${error.message}');
    return (relay: null, exitCode: 6);
  }

  final RelayServer server;
  try {
    server = await RelayServer.bind(
      address: options.address,
      port: options.port,
      options: RelayOptions(
        accessToken: token,
        maxRendezvous: options.maxRendezvous,
        // Off: every lone socket here is this desktop's own listener waiting
        // for an absent phone, and the token keeps strangers from parking one.
        loneTimeout: Duration.zero,
        onLog: (message) => out.writeln('relay: $message'),
      ),
    );
  } on SocketException catch (error) {
    err.writeln(
      'karmashala_host: port ${options.port} is not free '
      '(${error.osError?.message ?? error.message}). `--port=<n>` picks another.',
    );
    return (relay: null, exitCode: 5);
  }

  final pidFile = File(options.pidFile);
  try {
    pidFile.parent.createSync(recursive: true);
    pidFile.writeAsStringSync('$pid\n');
  } on FileSystemException catch (error) {
    await server.close();
    err.writeln(
      'karmashala_host: could not write ${options.pidFile} (${error.message}), '
      'so nothing could stop this relay later. Not started.',
    );
    return (relay: null, exitCode: 6);
  }

  out.writeln(
    'karmashala_host relay on ${server.address.address}:${server.port}, '
    'under its access token only',
  );
  return (relay: StartedRelay._(server, pidFile), exitCode: 0);
}

/// The subcommand: [startRelay], then wait to be told to stop. Started
/// detached over SSH like `serve`, so a closing channel's SIGHUP is ignored.
Future<int> runRelay(List<String> args, {IOSink? out, IOSink? err}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final started = await startRelay(args, out: sink, err: errSink);
  final relay = started.relay;
  if (relay == null) return started.exitCode;
  await sink.flush();

  final stopping = Completer<void>();
  void stop() {
    if (!stopping.isCompleted) stopping.complete();
  }

  final signals = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => stop()),
    if (!Platform.isWindows) ...[
      ProcessSignal.sigterm.watch().listen((_) => stop()),
      ProcessSignal.sighup.watch().listen((_) {}),
    ],
  ];
  await stopping.future;
  // Cancelled before closing: a live signal subscription keeps the isolate up.
  for (final signal in signals) {
    await signal.cancel();
  }
  await relay.stop();
  sink.writeln('karmashala_host relay stopped');
  return 0;
}

/// The token this relay serves under. **Minted on this machine** when the file
/// is absent, so the secret is never on a command line anybody's `ps` can read;
/// whoever deployed this reads it back over the channel they deployed with.
Future<String> _readOrMintToken(File file) async {
  try {
    if (file.existsSync()) {
      await _ownerOnly(file);
      final token = file.readAsStringSync().trim();
      if (!isUsableRelayToken(token)) {
        throw _TokenFileException(
          '${file.path} does not hold a usable token (32 or more url-safe '
          'characters). Delete it and start again to mint a new one.',
        );
      }
      return token;
    }
    file.parent.createSync(recursive: true);
    // Empty, then owner-only, then the secret: it is never in a file anybody
    // else could open, not even for the instant between two calls.
    file.createSync(exclusive: true);
    await _ownerOnly(file);
    final random = Random.secure();
    final token = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    file.writeAsStringSync('$token\n', flush: true);
    return token;
  } on FileSystemException catch (error) {
    throw _TokenFileException(
      'the token file ${file.path} could not be used (${error.message})',
    );
  }
}

Future<void> _ownerOnly(File file) async {
  if (Platform.isWindows) return; // A user profile is already per-user there.
  final ProcessResult result;
  try {
    result = await Process.run('chmod', ['600', file.path]);
  } on ProcessException catch (error) {
    throw _TokenFileException(
      '${file.path} could not be made owner-only (${error.message})',
    );
  }
  if (result.exitCode != 0) {
    throw _TokenFileException(
      '${file.path} could not be made owner-only '
      '(chmod exited ${result.exitCode})',
    );
  }
}

class _TokenFileException implements Exception {
  const _TokenFileException(this.message);
  final String message;
}

class _RelayArgs {
  const _RelayArgs({
    required this.port,
    required this.address,
    required this.tokenFile,
    required this.pidFile,
    required this.maxRendezvous,
  });

  final int port;
  final String address;
  final String tokenFile;
  final String pidFile;
  final int maxRendezvous;

  /// Null on anything unknown, missing or out of range. Strict on purpose: a
  /// `--token=…` somebody guessed at must be refused, not silently ignored
  /// while the secret sits in `ps`.
  static _RelayArgs? tryParse(List<String> args) {
    final values = <String, String>{};
    for (final arg in args) {
      final equals = arg.indexOf('=');
      if (!arg.startsWith('--') || equals < 0) return null;
      values[arg.substring(2, equals)] = arg.substring(equals + 1);
    }
    const known = {
      'port',
      'address',
      'token-file',
      'pid-file',
      'max-rendezvous',
    };
    if (values.keys.any((key) => !known.contains(key))) return null;

    final port = int.tryParse(values['port'] ?? '');
    final tokenFile = values['token-file'] ?? '';
    final pidFile = values['pid-file'] ?? '';
    if (port == null || port < 0 || port > 65535) return null;
    if (tokenFile.isEmpty || pidFile.isEmpty) return null;
    final rawMax = values['max-rendezvous'];
    final maxRendezvous = rawMax == null
        ? kBoxRelayMaxRendezvous
        : int.tryParse(rawMax);
    if (maxRendezvous == null || maxRendezvous < 1) return null;
    final address = values['address'] ?? '0.0.0.0';
    if (address.isEmpty) return null;
    return _RelayArgs(
      port: port,
      address: address,
      tokenFile: tokenFile,
      pidFile: pidFile,
      maxRendezvous: maxRendezvous,
    );
  }
}
