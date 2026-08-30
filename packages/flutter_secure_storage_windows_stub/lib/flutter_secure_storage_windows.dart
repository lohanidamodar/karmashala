/// Local Dart-only stand-in for `flutter_secure_storage_windows`.
///
/// The desktop build never constructs `SecureCompanionStore`, so nothing on
/// Windows should ever reach this. Every method throws rather than no-ops:
/// design §2 says a secret that could not be persisted must fail out loud,
/// never pretend it stuck.
library;

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// Registered on Windows in place of the real plugin; throws on any use.
class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  /// Registers this stub as the Windows implementation.
  static void registerWith() {
    FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();
  }

  Never _unsupported() => throw UnsupportedError(
        'flutter_secure_storage is stubbed out on Windows desktop '
        '(packages/flutter_secure_storage_windows_stub): the real plugin '
        'needs ATL, which this toolchain lacks. Companion mode (Android) '
        'uses the real Keystore implementation.',
      );

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      _unsupported();

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async =>
      _unsupported();

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _unsupported();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      _unsupported();

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      _unsupported();

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async =>
      _unsupported();
}
