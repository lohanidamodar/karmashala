import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  group('AppDatabase metadata', () {
    test('returns null for an unknown key', () async {
      expect(await db.readMetadata('missing'), isNull);
    });

    test('writes and reads a metadata value', () async {
      await db.writeMetadata('color', 'indigo');
      expect(await db.readMetadata('color'), 'indigo');
    });

    test('overwrites an existing key (upsert)', () async {
      await db.writeMetadata('color', 'indigo');
      await db.writeMetadata('color', 'amber');
      expect(await db.readMetadata('color'), 'amber');
    });
  });

  group('bootstrapMetadata', () {
    test('marks the first run and records the schema version', () async {
      final result = await bootstrapMetadata(db);

      expect(result.isFirstRun, isTrue);
      expect(result.schemaVersion, db.schemaVersion);
      expect(
        await db.readMetadata(MetadataKeys.schemaVersion),
        db.schemaVersion.toString(),
      );
      expect(await db.readMetadata(MetadataKeys.firstRunAt), isNotNull);
    });

    test('is not a first run on the second bootstrap', () async {
      final first = await bootstrapMetadata(db);
      final firstRunAt = await db.readMetadata(MetadataKeys.firstRunAt);

      final second = await bootstrapMetadata(db);

      expect(first.isFirstRun, isTrue);
      expect(second.isFirstRun, isFalse);
      // The original first-run timestamp is preserved.
      expect(await db.readMetadata(MetadataKeys.firstRunAt), firstRunAt);
    });
  });
}
