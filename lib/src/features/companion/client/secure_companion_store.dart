/// The phone's pairing record at rest, in the platform keystore.
///
/// Design §2: the device key lives in `flutter_secure_storage`
/// (Keystore/Keychain), never plain preferences. This is the only file that
/// touches the plugin; tests inject a fake backend via [withBackend], and the
/// desktop build never constructs it at all.
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

/// How long one keystore call may take before it counts as failed.
///
/// A platform channel that never comes back is worse than one that refuses:
/// `CompanionConnections.mutate` serialises every read-modify-write on ONE
/// static chain, so a single call that hangs stops every later one for the
/// life of the process — and the connect loop persists its generation counter
/// inside the dial. That is a phone reading "Connecting…" with a live desktop
/// at the other end and no way back short of force-quitting.
const Duration kSecureStoreTimeout = Duration(seconds: 5);

/// A [CompanionStore] over the platform's secure storage.
///
/// A read that fails for any reason — first run, a cleared keystore, a
/// restored backup the OS refuses to decrypt — answers null, which the
/// gateway reads as "unpaired"; a launch must never crash on bad storage.
/// Writes and deletes propagate their failures: a pairing that could not be
/// persisted has to fail out loud, not pretend it stuck.
///
/// Every call is bounded by [timeout]: not answering is a failure like any
/// other, and it must be reported as one rather than held open for ever.
class SecureCompanionStore implements CompanionStore {
  /// The real plugin-backed store the companion bootstrap uses.
  ///
  /// [onLog] defaults to [debugPrint] on purpose. A read that fails answers
  /// null, which the gateway reads as "unpaired" — indistinguishable, from
  /// the outside, from a phone that never paired at all. That is the right
  /// behaviour and the wrong silence: when a keystore stops decrypting what
  /// it holds (an app update that rotated the master key is the usual way),
  /// the only evidence is this line.
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
