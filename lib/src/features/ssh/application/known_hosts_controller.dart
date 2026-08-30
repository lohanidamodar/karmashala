import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/ssh_host_key.dart';
import 'ssh_providers.dart';

/// The host keys Chitragupta has been told to trust — its `known_hosts`.
///
/// Exposed as a list the user can actually see, because a pinned key that is
/// invisible is a pinned key nobody can audit: the only way to tell a rebuilt
/// machine from an impersonated one is to look at what was pinned and when.
class KnownHostsController extends Notifier<List<KnownHostKey>> {
  @override
  List<KnownHostKey> build() => ref.watch(knownHostDaoProvider).getAll();

  /// Forgets the pinned key for `host:port`.
  ///
  /// The one escape hatch for a legitimately rebuilt host, and deliberately not
  /// an acceptance of anything: afterwards the address is simply unknown again,
  /// so the next connection shows its fingerprint and asks.
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
