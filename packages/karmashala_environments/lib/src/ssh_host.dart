import 'package:agent_cli/process.dart';

/// How Karmashala authenticates to a remote host. A password is **never
/// persisted** — it is asked for per connection; key auth survives a restart.
enum SshAuthMethod {
  /// A private key file on a local machine, optionally passphrase-protected.
  privateKey,

  /// A password supplied by the user at connect time and held only in memory.
  password,
}

/// The Linux container behind an [SshHost] that Karmashala created: where its
/// Docker runs and what it was made with, so it can be started, stopped and
/// deleted there and described on its card.
class SshContainer {
  const SshContainer({
    required this.environmentId,
    required this.name,
    required this.id,
    required this.image,
    required this.cpus,
    required this.memoryMb,
    this.agents = const [],
  });

  /// The environment Docker runs in: `ssh:<id>` or `wsl:<distribution>`.
  final String environmentId;

  /// The Docker container name, always carrying Karmashala's prefix.
  final String name;

  /// The Docker container id, as `docker run` printed it.
  final String id;

  /// The stock image it was started from, e.g. `ubuntu:24.04`.
  final String image;

  final int cpus;
  final int memoryMb;

  /// The agent CLIs it was set up with, by their ids.
  final List<String> agents;

  @override
  bool operator ==(Object other) =>
      other is SshContainer &&
      other.environmentId == environmentId &&
      other.name == name &&
      other.id == id &&
      other.image == image &&
      other.cpus == cpus &&
      other.memoryMb == memoryMb &&
      _sameList(other.agents, agents);

  @override
  int get hashCode => Object.hash(
    environmentId,
    name,
    id,
    image,
    cpus,
    memoryMb,
    Object.hashAll(agents),
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
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
    this.viaHostId,
    this.container,
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

  /// The saved host this one is reached through: [host] and [port] are then
  /// dialled from that host, not from here. A container's sshd listens on
  /// that host's loopback only.
  final String? viaHostId;

  /// The container Karmashala created for this host, when it is one.
  final SshContainer? container;

  /// Id of the execution environment this host owns.
  String get environmentId => sshEnvironmentId(id);

  /// `user@host:port`, for logs and labels. Carries no secret.
  String get address => '$username@$host:$port';

  /// The name its host key is pinned under. A container's `127.0.0.1:<port>`
  /// is only unique on its own host, so it gets a name of its own.
  String get hostKeyName => container == null ? host : 'container:$id';

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
    String? viaHostId,
    SshContainer? container,
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
    viaHostId: viaHostId ?? this.viaHostId,
    container: container ?? this.container,
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
      other.createdAt == createdAt &&
      other.viaHostId == viaHostId &&
      other.container == container;

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
    viaHostId,
    container,
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

/// Where saved hosts are read from. The app backs this with the server's copy;
/// the pool only ever looks one up by id.
abstract interface class SshHostStore {
  SshHost? getById(String id);
}
