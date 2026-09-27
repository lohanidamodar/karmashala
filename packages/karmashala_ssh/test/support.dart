import 'package:karmashala_core/util.dart';
import 'package:karmashala_ssh/connection.dart';

/// When every test here happens.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

/// A clock that always says [now].
class FixedClock implements Clock {
  FixedClock(this.now);

  final DateTime now;

  @override
  DateTime nowUtc() => now;
}

/// Saved hosts, in memory — what the pool looks a host up in.
class MemoryHosts implements SshHostStore {
  final _hosts = <String, SshHost>{};

  void upsert(SshHost host) => _hosts[host.id] = host;

  @override
  SshHost? getById(String id) => _hosts[id];
}

/// Trusted keys, in memory, by the server's rule: a different key for an
/// address already trusted is refused, never overwritten.
class MemoryKnownHosts implements KnownHostStore {
  final _keys = <String, KnownHostKey>{};

  @override
  KnownHostKey? find(String host, int port) => _keys['$host:$port'];

  void forget(String host, int port) => _keys.remove('$host:$port');

  @override
  bool trust(KnownHostKey key) {
    final trusted = find(key.host, key.port);
    if (trusted != null) {
      return trusted.fingerprint == key.fingerprint &&
          trusted.keyType == key.keyType;
    }
    _keys['${key.host}:${key.port}'] = key;
    return true;
  }
}
