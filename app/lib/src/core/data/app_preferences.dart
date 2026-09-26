import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'data_client.dart';

/// This app's preferences — its settings and small remembered choices — as
/// the server keeps them: read at once from the copy, written to the copy
/// now and to the server after. A write the server refuses is logged and the
/// copy re-read.
class AppPreferences implements PreferenceStore {
  AppPreferences(this._client, {AppLogger? logger})
    : _log = logger ?? AppLogger.named('data.preferences');

  final DataClient _client;
  final AppLogger _log;

  /// Fires after any preference changed, from here or another client.
  Stream<void> get changes => _client.preferences.changes;

  @override
  String? read(String key) {
    _client.ensurePrimed(DataDomain.preferences);
    return _client.preferences[key];
  }

  @override
  void write(String key, String value) => _logged(key, writeStored(key, value));

  @override
  void remove(String key) => _logged(key, removeStored(key));

  /// [write], for a caller that waits for the server's answer.
  Future<void> writeStored(String key, String value) {
    if (read(key) == value) return Future.value();
    _client.preferences.setLocal(key, value);
    return _client.write(
      PreferenceSet(key, value),
      domain: DataDomain.preferences,
      apply: (_, revision) => _client.preferences.applyAt(key, value, revision),
    );
  }

  Future<void> removeStored(String key) {
    if (read(key) == null) return Future.value();
    _client.preferences.setLocal(key, null);
    return _client.write(
      PreferenceRemove(key),
      domain: DataDomain.preferences,
      apply: (_, revision) => _client.preferences.applyAt(key, null, revision),
    );
  }

  void _logged(String key, Future<void> write) => unawaited(
    write.catchError(
      (Object error) =>
          _log.warning('Keeping preference "$key" failed: $error'),
    ),
  );
}
