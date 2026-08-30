/// The relay binary. Run it anywhere with a public address:
///
/// ```
/// dart run bin/relay.dart --port 8787
/// PORT=8080 dart run bin/relay.dart
/// ```
///
/// It logs lifecycle counts only: never a rendezvous id, never a frame.
library;

import 'dart:async';
import 'dart:io';

import 'package:chitragupta_relay/chitragupta_relay.dart';

Future<void> main(List<String> arguments) async {
  final int port;
  final String address;
  try {
    port = _intArg(arguments, '--port', 'PORT') ?? kDefaultRelayPort;
    address = _stringArg(arguments, '--address', 'RELAY_ADDRESS') ?? '0.0.0.0';
  } on FormatException catch (error) {
    stderr.writeln('relay: ${error.message}');
    stderr.writeln(
      'usage: relay [--port N] [--address HOST] [--lone-timeout-s N] '
      '[--connections-per-minute N] [--quiet]',
    );
    exitCode = 64;
    return;
  }

  final quiet =
      arguments.contains('--quiet') ||
      Platform.environment['RELAY_QUIET'] == '1';
  final relay = await RelayServer.bind(
    address: address,
    port: port,
    options: RelayOptions(
      loneTimeout: Duration(
        seconds:
            _intArg(arguments, '--lone-timeout-s', 'RELAY_LONE_TIMEOUT_S') ??
            kDefaultLoneTimeout.inSeconds,
      ),
      connectionsPerMinute:
          _intArg(
            arguments,
            '--connections-per-minute',
            'RELAY_CONNECTIONS_PER_MINUTE',
          ) ??
          kDefaultConnectionsPerMinute,
      maxRendezvous:
          _intArg(arguments, '--max-rendezvous', 'RELAY_MAX_RENDEZVOUS') ??
          kDefaultMaxRendezvous,
      onLog: quiet ? null : (message) => stdout.writeln('relay: $message'),
    ),
  );

  stdout.writeln('relay: listening on ${relay.address.address}:${relay.port}');

  final done = Completer<void>();
  Future<void> stop(ProcessSignal signal) async {
    stdout.writeln('relay: stopping');
    await relay.close();
    if (!done.isCompleted) done.complete();
  }

  ProcessSignal.sigint.watch().listen(stop);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(stop);
  await done.future;
}

int? _intArg(List<String> arguments, String flag, String variable) {
  final raw = _stringArg(arguments, flag, variable);
  if (raw == null) return null;
  final value = int.tryParse(raw);
  if (value == null) throw FormatException('$flag needs a number, got "$raw"');
  return value;
}

String? _stringArg(List<String> arguments, String flag, String variable) {
  final index = arguments.indexOf(flag);
  if (index >= 0) {
    if (index + 1 >= arguments.length) {
      throw FormatException('$flag needs a value');
    }
    return arguments[index + 1];
  }
  final fromEnvironment = Platform.environment[variable];
  return (fromEnvironment != null && fromEnvironment.isNotEmpty)
      ? fromEnvironment
      : null;
}
