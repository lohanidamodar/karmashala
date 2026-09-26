import 'package:riverpod/riverpod.dart';

import 'package:karmashala_ssh/connection.dart';
import 'ssh_providers.dart';

/// The host keys Karmashala trusts — its `known_hosts`, kept by the server
/// and followed as they change. Visible, because spotting a rebuilt machine
/// means seeing what was pinned and when.
class KnownHostsController extends Notifier<List<KnownHostKey>> {
  @override
  List<KnownHostKey> build() {
    final data = ref.watch(knownHostsDataProvider);
    final keys = data.getAll();
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return keys;
  }

  /// Forgets the pinned key for `host:port` — the escape hatch for a rebuilt
  /// host, and no acceptance: the next connection shows a fingerprint and asks.
  Future<void> forget(String host, int port) async {
    await ref.read(knownHostsDataProvider).forget(host, port);
    state = ref.read(knownHostsDataProvider).getAll();
  }
}

final knownHostsControllerProvider =
    NotifierProvider<KnownHostsController, List<KnownHostKey>>(
      KnownHostsController.new,
    );
