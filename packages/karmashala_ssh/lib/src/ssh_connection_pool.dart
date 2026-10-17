import 'package:dartssh2/dartssh2.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'package:agent_cli/process.dart';
import 'ssh_asker.dart';
import 'ssh_connection.dart';
import 'ssh_host.dart';
import 'ssh_host_key.dart';
import 'ssh_host_key_verifier.dart';

/// One [SshConnection] per host, reused for the life of the process: a TCP connect
/// plus a key exchange per command turns a 3 ms probe into hundreds of ms.
class SshConnectionPool {
  SshConnectionPool({
    required this.hosts,
    required this.knownHosts,
    this.asker,
    this.keyReader = readLocalPrivateKey,
    this.onConnection,
    this.clock = const SystemClock(),
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('ssh.pool');

  final SshHostStore hosts;
  final KnownHostStore knownHosts;

  /// Who is asked what a connection cannot decide alone (the prompts
  /// contract). Absent: an unknown host key is refused rather than trusted,
  /// and a host that wants a password or passphrase gets none.
  final SshAsker? asker;

  /// How a private key file is read. The default opens it on Windows; the app
  /// supplies one that also understands a key inside a WSL distribution.
  final PrivateKeyReader keyReader;

  /// Told of each pooled connection as it is made — how its states are
  /// followed by whoever reports them.
  final void Function(String hostId, SshConnection connection)? onConnection;

  final Clock clock;
  final AppLogger _logger;

  final Map<String, SshConnection> _byHostId = {};

  /// The connection for [environment], which must be an SSH environment with a
  /// saved host.
  SshConnection forEnvironment(ExecutionEnvironment environment) {
    final hostId = environment.sshHostId;
    if (hostId == null) {
      throw ArgumentError(
        'SSH environment ${environment.id} has no ssh_host_id',
      );
    }
    return forHostId(hostId);
  }

  /// The connection for the saved host [hostId], created on first use.
  SshConnection forHostId(String hostId) {
    final existing = _byHostId[hostId];
    if (existing != null) return existing;

    final host = hosts.getById(hostId);
    if (host == null) {
      throw ArgumentError('No SSH host is saved with id "$hostId"');
    }
    final connection = _byHostId[hostId] = create(host);
    onConnection?.call(hostId, connection);
    return connection;
  }

  /// Builds a connection for [host] without registering it. Exposed so a "test
  /// connection" action can verify new settings before they are saved.
  SshConnection create(SshHost host) => SshConnection(
    host: host,
    verifier: SshHostKeyVerifier(
      knownHosts: knownHosts,
      host: host.hostKeyName,
      port: host.port,
      clock: clock,
      // A container Karmashala just made, reached over its host's loopback, is
      // pinned on first connect; a key that changes later is still refused.
      onUnknownHostKey: host.container != null
          ? (_) => true
          : asker?.hostKeyDecisionFor(host),
    ),
    passwordPrompt: asker?.password,
    passphrasePrompt: asker?.passphrase,
    keyReader: keyReader,
    openSocket: host.viaHostId == null ? null : _throughJump,
  );

  /// A channel to [host]'s address forwarded by the connection to the host it
  /// is reached through, used as the socket of a second SSH session.
  Future<SSHSocket> _throughJump(SshHost host) async {
    final viaId = host.viaHostId!;
    if (viaId == host.id) {
      throw SshConnectionException(
        '${host.name} is set to jump through itself.',
      );
    }
    final jump = await forHostId(viaId).client();
    try {
      return await jump.forwardLocal(host.host, host.port);
    } on SSHChannelOpenError catch (e) {
      throw SshConnectionException(
        'The jump host would not open a channel to ${host.host}:${host.port}',
        cause: e,
        retryable: true,
      );
    }
  }

  /// Drops the cached connection for [hostId], closing it.
  Future<void> evict(String hostId) async {
    final connection = _byHostId.remove(hostId);
    await connection?.close();
  }

  /// Closes every pooled connection. Called when the app shuts down.
  Future<void> closeAll() async {
    final open = _byHostId.values.toList();
    _byHostId.clear();
    for (final connection in open) {
      await connection.close();
    }
    if (open.isNotEmpty) {
      _logger.info('Closed ${open.length} SSH connection(s).');
    }
  }
}
