import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import 'idb_companion_locator.dart';
import 'idb_proto/idb.pbgrpc.dart';

/// A running `idb_companion` and the gRPC channel to it.
///
/// One companion serves exactly one simulator — `--udid` takes a single UDID —
/// so this is per-target, and two mirrored simulators are two processes.
class IdbCompanionConnection {
  // Positional because Dart has no private named parameters, and these are
  // all private fields of a privately-constructed object.
  IdbCompanionConnection._(
    this.udid,
    this.client,
    this._channel,
    this._process,
    this._socketPath,
    this._logger,
    this._errors,
    this._errorSubscription,
  );

  final String udid;
  final CompanionServiceClient client;

  final ClientChannel _channel;
  final ProcessHandle _process;
  final String _socketPath;
  final AppLogger _logger;
  final List<String> _errors;
  final StreamSubscription<String> _errorSubscription;
  bool _closed = false;

  /// The last lines the companion wrote to stderr.
  ///
  /// A gRPC failure on this side reports only that the connection went away.
  /// The companion says *why* on stderr, and quoting it is the difference
  /// between "idb is broken" and a sentence naming what it refused.
  List<String> get recentErrors => List.unmodifiable(_errors);

  /// Starts a companion for [udid] and dials it.
  ///
  /// Over a **domain socket**, not TCP. The companion's TCP listener binds
  /// `::` — every interface — and that is not configurable, so a mirrored
  /// simulator would be reachable from the network. A socket file is also a
  /// natural per-target identity and needs no port allocation.
  ///
  /// The handshake is one line of JSON on stdout, written the moment the
  /// server binds: `{"grpc_path":"/tmp/idb-xxxxxxxx.sock"}`. Waiting for it is
  /// what makes this deterministic — dialling on a timer races the bind, and
  /// the socket file appears before it is listening.
  static Future<IdbCompanionConnection> start({
    required CommandRunner runner,
    required IdbCompanionLocation companion,
    required String udid,
    String? socketPath,
    Duration timeout = const Duration(seconds: 30),
    AppLogger? logger,
  }) async {
    final log = logger ?? AppLogger.named('idb');
    final socket = socketPath ?? idbSocketPathFor(udid);

    // A socket file left by a companion that was killed rather than stopped.
    // Binding onto it fails, and the failure reads as "idb is broken" rather
    // than "there is a stale file here".
    final stale = File(socket);
    if (stale.existsSync()) {
      try {
        stale.deleteSync();
      } on FileSystemException {
        // Someone else's, or not ours to remove. The bind below will say so.
      }
    }

    final process = await runner.start(
      CommandRequest(
        executable: companion.executable,
        arguments: [
          '--udid', udid,
          '--grpc-domain-sock', socket,
          // Simulators only. Without this the companion also enumerates
          // physical devices, which needs entitlements we do not have and
          // slows every start.
          '--only', 'simulator',
          '--log-level', 'info',
        ],
      ),
    );

    // stderr is the companion's log; keep the tail so a failure can quote it
    // rather than reporting a bare timeout.
    final errors = <String>[];
    final errorSubscription = process.stderrLines.listen(
      (line) {
        errors.add(line);
        if (errors.length > 20) errors.removeAt(0);
      },
      onError: (Object _) {},
    );

    Future<void> abandon() async {
      await errorSubscription.cancel();
      await process.kill();
    }

    final String path;
    try {
      path = await _awaitHandshake(process).timeout(timeout);
    } on Object catch (error) {
      await abandon();
      throw CommandException(
        'idb_companion did not come up for $udid: $error'
        '${errors.isEmpty ? '' : '\n${errors.join('\n')}'}',
      );
    }
    // stderr keeps flowing rather than being cancelled here. The companion
    // reports why it refused a stream on stderr, and a gRPC failure on its own
    // says only "the connection went away" — which is what a video stream that
    // the companion rejected looks like from this side.
    final channel = ClientChannel(
      InternetAddress(path, type: InternetAddressType.unix),
      port: 0,
      options: const ChannelOptions(
        credentials: ChannelCredentials.insecure(),
      ),
    );
    log.info('idb_companion for $udid on $path');

    return IdbCompanionConnection._(
      udid,
      CompanionServiceClient(channel),
      channel,
      process,
      path,
      log,
      errors,
      errorSubscription,
    );
  }

  /// Reads the one line of JSON the companion writes when its server binds.
  static Future<String> _awaitHandshake(ProcessHandle process) async {
    await for (final line in process.stdoutLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        // The companion logs on stderr, so anything unparseable here is noise
        // from a future version rather than an error worth failing on.
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      final path = decoded['grpc_path'];
      if (path is String && path.isNotEmpty) return path;
    }
    throw StateError('the companion exited without announcing a socket');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _errorSubscription.cancel();
    try {
      await _channel.shutdown();
    } on Object {
      // The channel is going away regardless.
    }
    await _process.kill();
    try {
      final file = File(_socketPath);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Left behind; the next start removes it.
    }
    _logger.info('idb_companion for $udid stopped');
  }
}
