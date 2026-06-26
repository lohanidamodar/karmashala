import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  group('AppDatabase metadata', () {
    test('returns null for an unknown key', () {
      expect(db.readMetadata('missing'), isNull);
    });

    test('writes and reads a metadata value', () {
      db.writeMetadata('color', 'indigo');
      expect(db.readMetadata('color'), 'indigo');
    });

    test('overwrites an existing key (upsert)', () {
      db.writeMetadata('color', 'indigo');
      db.writeMetadata('color', 'amber');
      expect(db.readMetadata('color'), 'amber');
    });
  });

  group('bootstrapMetadata', () {
    test('marks the first run and records the schema version', () {
      final result = bootstrapMetadata(db);

      expect(result.isFirstRun, isTrue);
      expect(result.schemaVersion, db.schemaVersion);
      expect(
        db.readMetadata(MetadataKeys.schemaVersion),
        db.schemaVersion.toString(),
      );
      expect(db.readMetadata(MetadataKeys.firstRunAt), isNotNull);
    });

    test('is not a first run on the second bootstrap', () {
      final first = bootstrapMetadata(db);
      final firstRunAt = db.readMetadata(MetadataKeys.firstRunAt);

      final second = bootstrapMetadata(db);

      expect(first.isFirstRun, isTrue);
      expect(second.isFirstRun, isFalse);
      // The original first-run timestamp is preserved.
      expect(db.readMetadata(MetadataKeys.firstRunAt), firstRunAt);
    });
  });
}
