import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// Application-level key/value metadata.
///
/// Loop 0 ships exactly one table. It stores cross-cutting metadata such as the
/// persisted schema version and a first-run marker. The domain schema (projects,
/// repositories, sessions, agent installations, session events) is introduced in
/// Loop 1.
class AppMetadata extends Table {
  /// Stable identifier for the metadata entry (e.g. `schema_version`).
  TextColumn get key => text()();

  /// Stored value, serialised as text.
  TextColumn get value => text()();

  /// When the entry was last written (UTC).
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [AppMetadata])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Opens the database backed by a file in the per-user application-support
  /// directory (outside the project tree).
  factory AppDatabase.open() => AppDatabase(_openOnDisk());

  /// Opens an ephemeral in-memory database, for tests.
  factory AppDatabase.memory() => AppDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;

  /// Reads a metadata value by [key], or `null` if absent.
  Future<String?> readMetadata(String key) async {
    final row = await (select(
      appMetadata,
    )..where((row) => row.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// Inserts or updates a metadata [key] with [value], stamping `updatedAt`.
  Future<void> writeMetadata(String key, String value) {
    return into(appMetadata).insertOnConflictUpdate(
      AppMetadataCompanion.insert(
        key: key,
        value: value,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  static LazyDatabase _openOnDisk() {
    return LazyDatabase(() async {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'chitragupta.sqlite'));
      return NativeDatabase.createInBackground(file);
    });
  }
}
