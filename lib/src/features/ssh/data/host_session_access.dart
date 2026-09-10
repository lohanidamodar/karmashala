import 'dart:async';

import 'package:karmashala_core/logging.dart';
import '../domain/host_deployment.dart';
import '../domain/ssh_connection_state.dart';
import '../domain/ssh_host.dart';
import 'host_binaries.dart';
import 'host_deploy_target.dart';
import 'host_deployer.dart';
import 'ssh_connection.dart';

/// Everything a pane needs from one machine's session host. One per host, not
/// per pane: deploying is an upload and a handshake, too dear to repeat.
abstract class HostSessionAccess {
  String get address;

  /// The reading for this host, taken once per connection and shared. It
  /// carries the time it was taken, so a caller can say how old it is.
  Future<HostDeployment> deployment();

  /// A channel to speak the host protocol over.
  Future<RemoteChannel> exec(String command);

  /// Whether a tmux session of this name is running. **Null is not "no"**:
  /// moving a live tmux agent would open a second, empty session under its id.
  Future<bool?> hasTmuxSession(String name);

  /// Fires each time the connection to this machine is re-established after
  /// having dropped. A pane re-dials on this; nothing polls for it.
  Stream<void> get reconnected;
}

/// [HostSessionAccess] over the app's connection pool. The reading is dropped
/// when the connection drops: a machine may come back rebooted with no host.
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

  @override
  Future<RemoteChannel> exec(String command) => SshHostDeployTarget(_connection).exec(command);

  /// Asked with the *same* predicate the tmux script uses, so it answers what
  /// matters: would the fallback attach to something already there?
  @override
  Future<bool?> hasTmuxSession(String name) async {
    final quoted = "'${name.replaceAll("'", r"'\''")}'";
    final RemoteRun result;
    try {
      result = await SshHostDeployTarget(_connection).run(
        'if ! command -v tmux >/dev/null 2>&1; then echo karmashala-tmux-none; '
        'elif tmux has-session -t $quoted 2>/dev/null; then echo karmashala-tmux-present; '
        'else echo karmashala-tmux-absent; fi',
      );
    } on Object catch (e) {
      _logger.debug('${host.address} could not be asked about tmux session $name: $e');
      return null;
    }
    final said = result.stdout;
    if (said.contains('karmashala-tmux-present')) return true;
    if (said.contains('karmashala-tmux-absent') || said.contains('karmashala-tmux-none')) {
      return false;
    }
    return null;
  }

  final HostBinarySource binaries;

  /// Injected so a test can drive the deployer without an sshd.
  final HostDeployer Function(HostDeployTarget target)? deployerFactory;

  @override
  Future<HostDeployment> deployment() {
    final target = SshHostDeployTarget(_connection);
    final deployer =
        deployerFactory?.call(target) ?? HostDeployer(target: target, binaries: binaries);
    // Memoised on the future, not on the result: two panes opening at once must
    // share one deploy rather than racing two uploads onto the same path.
    return _reading ??= deployer.deploy().then((reading) {
      _logger.debug('${host.address}: ${reading.status.name} — ${reading.reason}');
      return reading;
    });
  }

  void _onConnectionState(SshConnectionState state) {
    switch (state.status) {
      case SshConnectionStatus.disconnected:
      case SshConnectionStatus.failed:
        _wasDown = true;
        // The machine may come back rebooted with nothing running on it, so
        // the reading is discarded rather than reused.
        _reading = null;
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

/// One [HostSessionAccess] per saved host: the reading and the connection have
/// the same lifetime, and a second instance would deploy a second time.
class HostSessionAccessRegistry {
  HostSessionAccessRegistry({required this.binaries, required this.connectionFor});

  final HostBinarySource binaries;
  final SshConnection Function(String hostId) connectionFor;

  final _byHostId = <String, SshHostSessionAccess>{};

  HostSessionAccess forHost(SshHost host) =>
      _byHostId[host.id] ??= SshHostSessionAccess(
        host: host,
        connection: connectionFor(host.id),
        binaries: binaries,
      );

  Future<void> dispose() async {
    for (final access in _byHostId.values) {
      await access.dispose();
    }
    _byHostId.clear();
  }
}
