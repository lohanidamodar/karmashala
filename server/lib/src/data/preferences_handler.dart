import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';

/// Client preferences at the server: the `app_metadata` rows `PreferenceKeys`
/// does not reserve for the server or another domain.
class PreferencesHandler {
  PreferencesHandler(this._db);

  final AppDatabase _db;

  Map<String, String> all() => {
    for (final row in _db.query('SELECT key, value FROM app_metadata;'))
      if (!PreferenceKeys.isReserved(row['key']! as String))
        row['key']! as String: row['value']! as String,
  };

  DataAck set(PreferenceSet request, List<DataChange> changes) {
    _checkKey(request.key);
    final problem = PreferenceKeys.valueProblem(request.value);
    if (problem != null) throw DataRefused.invalid(problem);
    // One statement: a client skips a write of what its copy already holds.
    _db.writeMetadata(request.key, request.value);
    changes.add(PreferenceChanged(request.key, request.value));
    return const DataAck();
  }

  DataAck remove(PreferenceRemove request, List<DataChange> changes) {
    _checkKey(request.key);
    _db.execute('DELETE FROM app_metadata WHERE key = ?;', [request.key]);
    changes.add(PreferenceChanged(request.key, null));
    return const DataAck();
  }

  void _checkKey(String key) {
    final problem = PreferenceKeys.keyProblem(key);
    if (problem != null) throw DataRefused.invalid(problem);
    if (PreferenceKeys.isReserved(key)) {
      throw DataRefused(
        DataRefusalCode.reserved,
        '"$key" is not a preference: the server or its own domain writes it',
      );
    }
  }
}
