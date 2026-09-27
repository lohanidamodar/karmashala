import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers the environment vault's requests (`EnvVaultRequest`: list
/// the names, set a value, remove one) — the server's vault, set once `serve`
/// has built it. Write-only: nothing it answers carries a value.
abstract interface class EnvVault {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(EnvVaultRequest<Object?> request);
}
