import '../../../core/database/app_database.dart';
import '../domain/browser_consent.dart';

/// Browser consent grants, kept in the `app_metadata` key/value table.
///
/// The same table `SettingsRepository` uses, and for the same reason: a grant
/// is one small JSON blob that is read on a tool call and written when someone
/// clicks a switch. Giving it a table of its own would mean a migration, and a
/// migration for a single row is a schema change nobody can undo cheaply.
///
/// It is deliberately *not* inside `Settings` itself. Settings is a value
/// object that is read, copied and written wholesale by the settings
/// controller; a permission record that can be clobbered by an unrelated
/// `copyWith` in a screen someone is editing is a permission record waiting to
/// be granted or revoked by accident.
class DatabaseConsentJournal implements ConsentJournal {
  const DatabaseConsentJournal(this._db);

  final AppDatabase _db;

  @override
  String? read(String key) => _db.readMetadata(key);

  @override
  void write(String key, String value) => _db.writeMetadata(key, value);
}
