import 'package:riverpod/riverpod.dart';

import '../domain/ssh_host_key.dart';
import 'ssh_providers.dart';

/// The host keys Karmashala trusts — its `known_hosts`. Visible, because
/// spotting a rebuilt machine means seeing what was pinned and when.
class KnownHostsController extends Notifier<List<KnownHostKey>> {
  @override
  List<KnownHostKey> build() => ref.watch(knownHostDaoProvider).getAll();

  /// Forgets the pinned key for `host:port` — the escape hatch for a rebuilt
  /// host, and no acceptance: the next connection shows a fingerprint and asks.
  void forget(String host, int port) {
    ref.read(knownHostDaoProvider).forget(host, port);
    state = ref.read(knownHostDaoProvider).getAll();
  }

  /// Re-reads the store, for after a connection pinned something new.
  void refresh() => state = ref.read(knownHostDaoProvider).getAll();
}

final knownHostsControllerProvider =
    NotifierProvider<KnownHostsController, List<KnownHostKey>>(
      KnownHostsController.new,
    );
