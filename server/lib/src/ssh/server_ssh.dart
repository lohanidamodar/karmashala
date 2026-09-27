import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart' show Clock, SystemClock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/runner.dart';
import 'package:karmashala_store/database.dart';

import '../data/data_service.dart';
import '../data/ssh_work.dart';
import 'ssh_prompts.dart';

/// **SSH reached by the server itself** (slice 3a). One connection per saved
/// host, over the server's own `ssh_hosts` and trusted keys, with the private
/// key read on this machine ([EnvironmentPrivateKeyReader], a WSL
/// distribution's too) — so a key and a password never leave it. [runners]
/// is the server's runner factory: this machine, its WSL distributions, and
/// an SSH environment through this pool. Detection, checks, worktrees,
/// review anchors, project scans and the delivery readings reach an SSH box
/// through it, with the app closed or on another machine.
///
/// What a connection cannot decide alone goes to a person through [prompts];
/// where each connection stands is told to every client
/// ([SshConnectionChanged]). A trust a person gives is recorded through the
/// data service, so every client hears of the key.
class ServerSsh implements SshWork {
  ServerSsh({
    required DataService data,
    required AppDatabase database,
    Clock clock = const SystemClock(),
    PrivateKeyReader? readKey,
    Duration promptWait = const Duration(minutes: 5),
  }) : _data = data {
    prompts = SshPrompts(
      tell: data.announce,
      canAsk: () => data.hasSubscribers,
      wait: promptWait,
    );
    final keys = EnvironmentPrivateKeyReader(
      environmentOf: (id) =>
          data.environments.where((e) => e.id == id).firstOrNull,
      readLocal: readKey ?? readLocalPrivateKey,
    );
    pool = SshConnectionPool(
      hosts: _StoredHosts(SshHostDao(database)),
      knownHosts: _TrustedKeys(KnownHostDao(database), data),
      hostKeyDecisionFor: (host) =>
          (presentation) => prompts.askHostKey(host, presentation),
      passwordPrompt: (host) => prompts.askSecret(host, SshPromptKind.password),
      passphrasePrompt: (host) =>
          prompts.askSecret(host, SshPromptKind.passphrase),
      keyReader: keys.read,
      onConnection: _follow,
      clock: clock,
    );
    runners = SshCommandRunnerFactory(sshConnections: () => pool);
    data.addChangeListener(_hostsChanged);
  }

  final DataService _data;
  late final SshPrompts prompts;
  late final SshConnectionPool pool;

  /// Where the server runs a command: here, in WSL, or on an SSH box.
  late final CommandRunnerFactory runners;

  final _states = <String, SshConnectionState>{};
  final _following = <String, StreamSubscription<SshConnectionState>>{};

  /// Answers the clients' SSH work from now on.
  void attach() => _data.sshWork = this;

  @override
  Future<Object?> handle(SshWorkRequest<Object?> request) async =>
      switch (request) {
        SshTest(:final hostId, :final draft) => await test(
          draft ??
              _StoredHosts.of(pool, hostId!) ??
              (throw DataRefused.notFound('no SSH host is saved as $hostId')),
        ),
        SshDisconnect(:final hostId) => await () async {
          await disconnect(hostId);
          return const DataAck();
        }(),
        final SshAnswerPrompt answer => () {
          prompts.answer(answer);
          return const DataAck();
        }(),
      };

  @override
  List<DataChange> greeting() => [
    for (final MapEntry(:key, :value) in _states.entries)
      if (value.status != SshConnectionStatus.idle)
        SshConnectionChanged(key, value),
    ...prompts.open,
  ];

  /// Connects to [host] once — a connection of its own, never the pooled
  /// one — runs `uname -sr` and hangs up. A failure is an answer too.
  Future<SshTestResult> test(SshHost host) async {
    final connection = pool.create(host);
    final stopwatch = Stopwatch()..start();
    try {
      await connection.client();
      final result = await SshCommandRunner(
        environmentId: host.environmentId,
        connection: connection,
      ).run(const CommandRequest(executable: 'uname', arguments: ['-sr']));
      final banner = result.ok
          ? result.stdout.trim()
          : 'connected (uname exited ${result.exitCode})';
      return SshTestResult(
        connected: true,
        message: banner.isEmpty ? 'connected' : banner,
        elapsed: stopwatch.elapsed,
      );
    } on Object catch (error) {
      return SshTestResult(
        connected: false,
        message: describeSshFailure(error),
        elapsed: stopwatch.elapsed,
        rejectedKey: hostKeyRejectionIn(error)?.presentation,
      );
    } finally {
      await connection.close();
    }
  }

  /// Closes the pooled connection to [hostId]; the next command dials again.
  Future<void> disconnect(String hostId) async {
    await _following.remove(hostId)?.cancel();
    await pool.evict(hostId);
    _set(hostId, const SshConnectionState.idle());
  }

  Future<void> close() async {
    _data.removeChangeListener(_hostsChanged);
    prompts.close();
    for (final subscription in _following.values) {
      await subscription.cancel();
    }
    _following.clear();
    await pool.closeAll();
  }

  void _follow(String hostId, SshConnection connection) {
    unawaited(_following.remove(hostId)?.cancel());
    _following[hostId] = connection.states.listen(
      (state) => _set(hostId, state),
    );
  }

  void _set(String hostId, SshConnectionState state) {
    if (_states[hostId] == state) return;
    _states[hostId] = state;
    _data.announce([SshConnectionChanged(hostId, state)]);
  }

  /// A host edited or removed is dialled afresh: its connection was made
  /// with the settings it had.
  void _hostsChanged(List<DataChange> changes) {
    for (final change in changes) {
      final hostId = switch (change) {
        SshHostTouched(:final id) || SshHostRemoved(:final id) => id,
        _ => null,
      };
      if (hostId != null && _following.containsKey(hostId)) {
        unawaited(disconnect(hostId));
      }
    }
  }
}

/// The saved hosts, read from the server's own store.
class _StoredHosts implements SshHostStore {
  _StoredHosts(this._dao);

  final SshHostDao _dao;

  static SshHost? of(SshConnectionPool pool, String id) =>
      pool.hosts.getById(id);

  @override
  SshHost? getById(String id) => _dao.getById(id);
}

/// The trusted keys, read from the store and trusted through the data
/// service — the one writer, which refuses a different key for an address
/// already trusted and tells every client of a new one.
class _TrustedKeys implements KnownHostStore {
  _TrustedKeys(this._dao, this._data);

  final KnownHostDao _dao;
  final DataService _data;

  @override
  KnownHostKey? find(String host, int port) => _dao.find(host, port);

  @override
  bool trust(KnownHostKey key) {
    try {
      _data.applyAsServer(KnownHostTrust(key));
      return true;
    } on DataRefused {
      return false;
    }
  }
}
