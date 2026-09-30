import 'package:store_console/store_console.dart';

import '../../../core/server/secure_machine_store.dart';

/// Where each store's credential is kept in the OS keystore. A probe has its
/// own names, so it can never overwrite the real app's (PROJECT.md §23).
class StoreVaultKeys {
  const StoreVaultKeys({required bool probe})
    : apple = probe
          ? 'karmashala.stores.probe.apple'
          : 'karmashala.stores.apple',
      play = probe ? 'karmashala.stores.probe.play' : 'karmashala.stores.play';

  final String apple;
  final String play;
}

/// The [SecretVault] over the platform keystore, on desktop and phone alike.
/// An unreadable keystore answers null — "no credential" — and a write that
/// fails throws.
class SecureSecretVault implements SecretVault {
  SecureSecretVault({SecureCompanionStore? store})
    : _store = store ?? SecureCompanionStore();

  final SecureCompanionStore _store;

  @override
  Future<String?> read(String key) => _store.read(key);

  @override
  Future<void> write(String key, String value) => _store.write(key, value);

  @override
  Future<void> delete(String key) => _store.delete(key);
}
