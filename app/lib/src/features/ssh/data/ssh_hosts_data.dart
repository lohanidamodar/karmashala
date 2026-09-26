import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The saved SSH hosts as the server keeps them — configuration, never a
/// credential: a password is asked per connection and a key is read from
/// the file [SshHost.privateKey] names. Read from this app's copy; saved and
/// removed through the server, which writes each host's `ssh:<id>`
/// environment with it and refuses to remove one projects still use.
class SshHostsData implements SshHostStore {
  SshHostsData(this._client);

  final DataClient _client;

  Stream<void> get changes => _client.sshHosts.changes;

  @override
  SshHost? getById(String id) => _client.sshHosts[id];

  List<SshHost> getAll() => [..._client.sshHosts.values]..sort(compareSshHosts);

  /// Saves [host] with its environment; answers the host as saved. Throws
  /// [DataRefused] for one out of shape.
  Future<SshHost> put(SshHost host) => _client.write(
    SshHostPut(host),
    domain: DataDomain.environments,
    apply: (saved, revision) =>
        _client.sshHosts.applyAt(saved.id, saved, revision),
  );

  /// Removes host [id] and its environment. Throws [DataRefused] while
  /// projects still use it, naming them.
  Future<void> delete(String id) =>
      _client.write(SshHostDelete(id), domain: DataDomain.environments);
}

/// The host keys trusted for SSH hosts — Karmashala's `known_hosts`, by
/// fingerprint. A key is trusted only after a person accepted it, and **the
/// server refuses a different key for an address already trusted**: a
/// changed key is never overwritten by a trust, only by forgetting it first.
class KnownHostsData implements KnownHostStore {
  KnownHostsData(this._client);

  final DataClient _client;

  Stream<void> get changes => _client.knownHosts.changes;

  @override
  KnownHostKey? find(String host, int port) =>
      _client.knownHosts[DataClient.knownHostKey(host, port)];

  List<KnownHostKey> getAll() =>
      [..._client.knownHosts.values]..sort(compareKnownHosts);

  /// Trusts [key] a person accepted. False when the server refused it — a
  /// different key is trusted for that address — or could not be reached:
  /// the connection is then refused like a changed key.
  @override
  Future<bool> trust(KnownHostKey key) async {
    try {
      await _client.write(
        KnownHostTrust(key),
        domain: DataDomain.environments,
        apply: (trusted, revision) => _client.knownHosts.applyAt(
          DataClient.knownHostKey(trusted.host, trusted.port),
          trusted,
          revision,
        ),
      );
      return true;
    } on DataRefused {
      return false;
    }
  }

  /// Forgets the key trusted for `host:port` — the next connection asks
  /// again.
  Future<void> forget(String host, int port) => _client.write(
    KnownHostForget(host, port),
    domain: DataDomain.environments,
  );
}

final sshHostsDataProvider = Provider<SshHostsData>(
  (ref) => SshHostsData(ref.watch(dataClientProvider)),
);

final knownHostsDataProvider = Provider<KnownHostsData>(
  (ref) => KnownHostsData(ref.watch(dataClientProvider)),
);
