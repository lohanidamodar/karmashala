import 'package:agent_cli/process.dart';

/// How Karmashala authenticates to a remote host. A password is **never
/// persisted** — it is asked for per connection; key auth survives a restart.
enum SshAuthMethod {
  /// A private key file on a local machine, optionally passphrase-protected.
  privateKey,

  /// A password supplied by the user at connect time and held only in memory.
  password,
}

/// A remote machine reached over SSH. **Configuration**, not a secret store: it
/// holds *where* the private key lives, never a key, password or passphrase.
class SshHost {
  const SshHost({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.createdAt,
    this.privateKey,
    this.defaultDirectory,
  });

  /// Stable identifier; the owning environment is `ssh:<id>`.
  final String id;

  /// Human-readable label, e.g. `build-box`.
  final String name;

  /// Hostname or IP address.
  final String host;

  final int port;

  /// The remote account to log in as.
  final String username;

  final SshAuthMethod authMethod;

  /// Path to the private key **on a local environment** (principle 2: the path
  /// carries the environment that owns it). Null for password auth.
  final EnvironmentPath? privateKey;

  /// Optional starting directory for browsing, a path in *this host's*
  /// environment (`ssh:<id>`).
  final EnvironmentPath? defaultDirectory;

  final DateTime createdAt;

  /// Id of the execution environment this host owns.
  String get environmentId => sshEnvironmentId(id);

  /// `user@host:port`, for logs and labels. Carries no secret.
  String get address => '$username@$host:$port';

  SshHost copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    SshAuthMethod? authMethod,
    EnvironmentPath? privateKey,
    EnvironmentPath? defaultDirectory,
    DateTime? createdAt,
  }) => SshHost(
    id: id ?? this.id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    authMethod: authMethod ?? this.authMethod,
    privateKey: privateKey ?? this.privateKey,
    defaultDirectory: defaultDirectory ?? this.defaultDirectory,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is SshHost &&
      other.id == id &&
      other.name == name &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.authMethod == authMethod &&
      other.privateKey == privateKey &&
      other.defaultDirectory == defaultDirectory &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    host,
    port,
    username,
    authMethod,
    privateKey,
    defaultDirectory,
    createdAt,
  );

  /// Deliberately prints the address and never the key path or any credential.
  @override
  String toString() => 'SshHost($id, $address)';
}

/// The execution-environment id owned by the SSH host [hostId].
String sshEnvironmentId(String hostId) => 'ssh:$hostId';

/// The [ExecutionEnvironment] record for [host].
ExecutionEnvironment sshEnvironment(SshHost host) => ExecutionEnvironment(
  id: host.environmentId,
  kind: EnvironmentKind.ssh,
  name: host.name,
  sshHostId: host.id,
  createdAt: host.createdAt,
);
