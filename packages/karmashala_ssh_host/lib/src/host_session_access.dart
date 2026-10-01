import 'dart:async';
import 'dart:convert';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_ssh/connection.dart';

import 'host_binaries.dart';
import 'host_deploy_target.dart';
import 'host_deployer.dart';

/// [HostSessionAccess] for one SSH box, over the server's connection pool
/// (slice 5d: the server deploys, links and relays; no client dials a box).
/// The reading is dropped when the connection drops: a machine may come back
/// rebooted with no host.
class SshHostSessionAccess implements HostSessionAccess {
  SshHostSessionAccess({
    required this.host,
    required SshConnection connection,
    required this.binaries,
    this.deployerFactory,
    AppLogger? logger,
  }) : _connection = connection,
       _logger = logger ?? AppLogger.named('ssh.host') {
    _states = connection.states.listen(_onConnectionState);
  }

  final SshHost host;
  final SshConnection _connection;
  final AppLogger _logger;

  late final StreamSubscription<SshConnectionState> _states;
  final _reconnected = StreamController<void>.broadcast();
  Future<HostDeployment>? _reading;
  var _wasDown = false;

  @override
  String get address => host.address;

  @override
  Stream<void> get reconnected => _reconnected.stream;

  /// What runs commands and uploads on the box — the deployer's, the relay
  /// set-up's and a pairing's.
  HostDeployTarget get target =>
      deployTarget ?? SshHostDeployTarget(_connection);

  /// Set by a test to put a box without an sshd behind this access.
  HostDeployTarget? deployTarget;

  @override
  Future<RemoteChannel> exec(String command) => target.exec(command);

  final HostBinarySource binaries;

  /// Injected so a test can drive the deployer without an sshd.
  final HostDeployer Function(HostDeployTarget target)? deployerFactory;

  HostDeployer deployer() =>
      deployerFactory?.call(target) ??
      HostDeployer(target: target, binaries: binaries);

  @override
  Future<HostDeployment> deployment() {
    // Memoised on the future, not on the result: two opens at once must share
    // one deploy rather than racing two uploads onto the same path. A failure
    // is not memoised, or every later open would inherit it.
    return _reading ??= deployer()
        .deploy()
        .timeout(deployTimeout)
        .then(
          (reading) {
            _logger.debug(
              '${host.address}: ${reading.status.name} — ${reading.reason}',
            );
            return reading;
          },
          onError: (Object error, StackTrace stack) {
            _reading = null;
            Error.throwWithStackTrace(error, stack);
          },
        );
  }

  /// The executable of the host already running on the box, or null — read
  /// without deploying, installing or starting anything
  /// ([HostDeployer.runningHost]).
  Future<String?> runningHost() =>
      deployer().runningHost().timeout(const Duration(seconds: 30));

  /// Drops the shared reading, so the next caller deploys — and reads — again.
  /// For after an explicit install or remove, and for Retry: a reading that
  /// said `noBinary` is otherwise kept for the life of the connection.
  void forgetReading() => _reading = null;

  /// Bounds the whole deploy — the upload of the host binary included.
  static const deployTimeout = Duration(minutes: 3);

  Future<String?>? _shell;

  /// This box's login shell for this user, or null when it could not be
  /// asked. The session host spawns exactly the argv it is given, so a shell
  /// pane that does not ask gets whatever was hardcoded.
  Future<String?> loginShell() => _shell ??= _readLoginShell();

  /// `$SHELL`, which sshd sets from the passwd entry. Marked output, so a
  /// login banner on stdout cannot be mistaken for the answer.
  Future<String?> _readLoginShell() async {
    try {
      final result = await target
          .run('printf "karmashala-shell:%s\\n" "\${SHELL:-}"')
          .timeout(const Duration(seconds: 20));
      for (final line in const LineSplitter().convert(result.stdout)) {
        const marker = 'karmashala-shell:';
        if (!line.startsWith(marker)) continue;
        final shell = line.substring(marker.length).trim();
        if (shell.isNotEmpty) return shell;
      }
    } on Object catch (e) {
      _logger.debug('${host.address} could not be asked for its shell: $e');
    }
    // Asked and unanswered is not a shell; the caller keeps its own default.
    _shell = null;
    return null;
  }

  void _onConnectionState(SshConnectionState state) {
    switch (state.status) {
      case SshConnectionStatus.disconnected:
      case SshConnectionStatus.failed:
        _wasDown = true;
        // The machine may come back rebooted with nothing running on it, so
        // the reading is discarded rather than reused.
        _reading = null;
        _shell = null;
      case SshConnectionStatus.connected:
        if (!_wasDown) return;
        _wasDown = false;
        if (!_reconnected.isClosed) _reconnected.add(null);
      case SshConnectionStatus.idle:
      case SshConnectionStatus.connecting:
        break;
    }
  }

  Future<void> dispose() async {
    await _states.cancel();
    await _reconnected.close();
  }
}
