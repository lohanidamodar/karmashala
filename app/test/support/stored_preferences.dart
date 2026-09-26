import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;
import 'package:karmashala_store/database.dart';

/// The preferences as the store holds them, for a test to seed before the
/// app reads them, or to read back what the app wrote through its data
/// client (which, in a test, writes before it returns).
class StoredPreferences implements PreferenceStore {
  StoredPreferences(this._db);

  final AppDatabase _db;

  @override
  String? read(String key) => _db.readMetadata(key);

  @override
  void write(String key, String value) => _db.writeMetadata(key, value);

  @override
  void remove(String key) =>
      _db.execute('DELETE FROM app_metadata WHERE key = ?;', [key]);
}
