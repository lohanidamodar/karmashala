import '../../../core/database/app_database.dart';
import 'package:karmashala_browser/browser.dart';

/// Browser consent grants in the `app_metadata` key/value table — deliberately
/// *not* inside `Settings`, which is copied and written wholesale.
class DatabaseConsentJournal implements ConsentJournal {
  const DatabaseConsentJournal(this._db);

  final AppDatabase _db;

  @override
  String? read(String key) => _db.readMetadata(key);

  @override
  void write(String key, String value) => _db.writeMetadata(key, value);
}
