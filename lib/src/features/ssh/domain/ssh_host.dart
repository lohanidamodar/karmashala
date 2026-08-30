import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';

/// How Chitragupta authenticates to a remote host.
///
/// Password auth exists because some hosts allow nothing else, but the password
/// itself is **never persisted** — it is asked for per connection. Key auth is
/// the default and the only one that survives a restart unattended.
enum SshAuthMethod {
  /// A private key file on a local machine, optionally passphrase-protected.
  privateKey,

  /// A password supplied by the user at connect time and held only in memory.
  password,
}

/// A remote machine Chitragupta can run agents on, reached over SSH.
///
/// This is **configuration**, not a secret store: it holds the address, the
/// account, and *where the private key lives* — never a password, never a
/// passphrase, and never private key material. Those are supplied per
/// connection through `SshCredentialPrompt` and kept in memory only.
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
  /// carries the environment that owns it — a key at `C:\Users\me\.ssh\id_ed25519`
  /// is a Windows path, not a remote one). Null for password auth.
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
