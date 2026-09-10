import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'package:agent_cli/process.dart';
import 'ssh_connection.dart';
import 'ssh_host.dart';
import 'ssh_host_key.dart';
import 'ssh_host_key_verifier.dart';

/// One [SshConnection] per host, reused for the life of the app: a TCP connect
/// plus a key exchange per command turns a 3 ms probe into hundreds of ms.
class SshConnectionPool {
  SshConnectionPool({
    required this.hosts,
    required this.knownHosts,
    this.onUnknownHostKey,
    this.passwordPrompt,
    this.passphrasePrompt,
    this.keyReader = readLocalPrivateKey,
    this.clock = const SystemClock(),
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('ssh.pool');

  final SshHostStore hosts;
  final KnownHostStore knownHosts;

  /// Asked when a host presents an unrecognised key. Absent means unknown hosts
  /// are refused rather than trusted (see [SshHostKeyVerifier]).
  final HostKeyTrustDecision? onUnknownHostKey;

  final SshSecretPrompt? passwordPrompt;
  final SshSecretPrompt? passphrasePrompt;

  /// How a private key file is read. The default opens it on Windows; the app
  /// supplies one that also understands a key inside a WSL distribution.
  final PrivateKeyReader keyReader;

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
    return _byHostId[hostId] = create(host);
  }

  /// Builds a connection for [host] without registering it. Exposed so a "test
  /// connection" action can verify new settings before they are saved.
  SshConnection create(SshHost host) => SshConnection(
    host: host,
    verifier: SshHostKeyVerifier(
      knownHosts: knownHosts,
      host: host.host,
      port: host.port,
      clock: clock,
      onUnknownHostKey: onUnknownHostKey,
    ),
    passwordPrompt: passwordPrompt,
    passphrasePrompt: passphrasePrompt,
    keyReader: keyReader,
  );

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
