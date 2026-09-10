/// The phone's pairing record at rest, in the platform keystore — the device
/// key lives in Keystore/Keychain, never plain preferences (Design §2). The
/// only file that touches the plugin.
library;

// The backend functions are named for callers but stored privately, which the
// initializing-formals lint cannot express.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:karmashala_remote/client.dart';

/// Reads one value, or null when the key has never been written.
typedef SecureRead = Future<String?> Function(String key);

typedef SecureWrite = Future<void> Function(String key, String value);

typedef SecureDelete = Future<void> Function(String key);

/// How long one keystore call may take. `CompanionConnections.mutate` chains
/// every write, so one hung call stops every later one for the process's life.
const Duration kSecureStoreTimeout = Duration(seconds: 5);

/// A [CompanionStore] over the platform's secure storage: a failed read answers
/// null ("unpaired"), writes propagate, and every call is bounded by [timeout].
class SecureCompanionStore implements CompanionStore {
  /// The real plugin-backed store. [onLog] defaults to [debugPrint]: a keystore
  /// that stopped decrypting looks exactly like a phone that never paired.
  factory SecureCompanionStore({
    void Function(String message)? onLog,
    Duration timeout = kSecureStoreTimeout,
  }) {
    const storage = FlutterSecureStorage();
    return SecureCompanionStore.withBackend(
      read: (key) => storage.read(key: key),
      write: (key, value) => storage.write(key: key, value: value),
      delete: (key) => storage.delete(key: key),
      onLog: onLog ?? (message) => debugPrint('[companion store] $message'),
      timeout: timeout,
    );
  }

  /// The seam tests use — never the real plugin.
  SecureCompanionStore.withBackend({
    required SecureRead read,
    required SecureWrite write,
    required SecureDelete delete,
    void Function(String message)? onLog,
    this.timeout = kSecureStoreTimeout,
  }) : _read = read,
       _write = write,
       _delete = delete,
       _onLog = onLog;

  final SecureRead _read;
  final SecureWrite _write;
  final SecureDelete _delete;

  /// The deadline on every call into the platform keystore.
  final Duration timeout;

  /// Lifecycle only — never called with stored values.
  final void Function(String message)? _onLog;

  @override
  Future<String?> read(String key) async {
    try {
      return await _read(key).timeout(timeout);
    } on Object catch (error) {
      // Unreadable means unpaired, never a crash on launch.
      _onLog?.call('secure storage read failed: $error');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _write(key, value).timeout(timeout);
    } on TimeoutException {
      _onLog?.call('secure storage write did not answer in $timeout');
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _delete(key).timeout(timeout);
    } on TimeoutException {
      _onLog?.call('secure storage delete did not answer in $timeout');
      rethrow;
    }
  }
}
