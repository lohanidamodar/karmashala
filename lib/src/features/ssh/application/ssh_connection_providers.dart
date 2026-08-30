import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner.dart';
import '../../../core/process/ssh_command_runner.dart';
import '../data/ssh_connection.dart';
import '../data/ssh_connection_pool.dart';
import '../domain/ssh_connection_state.dart';
import '../domain/ssh_host.dart';
import 'ssh_failure.dart';
import 'ssh_providers.dart';

/// The live lifecycle of the connection to one saved host.
///
/// Watching this does **not** dial: `SshConnectionPool.forHostId` builds the
/// connection object without opening a socket, so a row can show "not
/// connected" without connecting to say so. The current state is emitted
/// immediately and then every transition, so a UI that subscribes late still
/// shows the truth rather than an empty stream that looks like idle.
final sshConnectionStateProvider = StreamProvider.autoDispose
    .family<SshConnectionState, String>((ref, hostId) {
      final SshConnection connection;
      try {
        connection = ref.watch(sshConnectionPoolProvider).forHostId(hostId);
      } on ArgumentError {
        // The host was deleted while its row was still on screen.
        return Stream.value(const SshConnectionState.idle());
      }
      final states = StreamController<SshConnectionState>();
      final subscription = connection.states.listen(
        states.add,
        onDone: () {
          if (!states.isClosed) states.close();
        },
      );
      states.add(connection.state);
      ref.onDispose(() {
        subscription.cancel();
        if (!states.isClosed) states.close();
      });
      return states.stream;
    });

/// What a "test connection" found out.
class SshHostProbe {
  const SshHostProbe._({
    required this.connected,
    required this.message,
    this.error,
    this.elapsed,
  });

  const SshHostProbe.success({required String message, Duration? elapsed})
    : this._(connected: true, message: message, elapsed: elapsed);

  /// Whether the handshake and authentication succeeded.
  final bool connected;

  /// What to show the user — the remote's own answer on success, the real
  /// failure on the way down.
  final String message;

  /// The failure, kept so the UI can recognise a refused host key rather than
  /// string-matching its message.
  final Object? error;

  final Duration? elapsed;
}

/// Connects to [host] once, runs one command, and hangs up.
///
/// Built through [SshConnectionPool.create], which deliberately does *not*
/// register the connection: this is how unsaved settings get verified before
/// they are written, and how a test never leaves a pooled connection behind for
/// the rest of the app to inherit.
Future<SshHostProbe> probeSshHost(SshConnectionPool pool, SshHost host) async {
  final connection = pool.create(host);
  final stopwatch = Stopwatch()..start();
  try {
    await connection.client();
    final runner = SshCommandRunner(
      environmentId: host.environmentId,
      connection: connection,
    );
    final result = await runner.run(
      const CommandRequest(executable: 'uname', arguments: ['-sr']),
    );
    stopwatch.stop();
    final banner = result.ok
        ? result.stdout.trim()
        : 'connected (uname exited ${result.exitCode})';
    return SshHostProbe.success(
      message: banner.isEmpty ? 'connected' : banner,
      elapsed: stopwatch.elapsed,
    );
  } on Object catch (e) {
    stopwatch.stop();
    return SshHostProbe._(
      connected: false,
      message: describeSshFailure(e),
      error: e,
      elapsed: stopwatch.elapsed,
    );
  } finally {
    await connection.close();
  }
}
