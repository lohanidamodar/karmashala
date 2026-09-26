// The package's reason for existing: the app's schema, opened and migrated
// from a plain Dart program with no Flutter, no `flutter_tester` and no
// Riverpod. What runs here is what the session host binary will run on a
// machine with no GUI.
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:test/test.dart';

void main() {
  test('an in-memory database walks the whole ladder', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final highest = schemaMigrations.keys.reduce((a, b) => a > b ? a : b);
    expect(db.schemaVersion, highest);
    expect(
      db.query('PRAGMA user_version;').single['user_version'],
      highest,
      reason: 'every step ran, not just the table creation',
    );
  });

  test('metadata round-trips', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    expect(db.readMetadata('absent'), isNull);
    db.writeMetadata('greeting', 'namaste');
    expect(db.readMetadata('greeting'), 'namaste');
    db.writeMetadata('greeting', 'pheri bhetaula');
    expect(db.readMetadata('greeting'), 'pheri bhetaula');
  });

  test('a transaction rolls back what it could not finish', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    expect(
      () => db.transaction(() {
        db.writeMetadata('half', 'written');
        throw const FormatException('abandoned');
      }),
      throwsA(isA<FormatException>()),
    );
    expect(db.readMetadata('half'), isNull);
  });

  test('the column conversions survive a round trip', () {
    final when = DateTime.utc(2026, 9, 15, 3, 41, 59, 123, 456);
    expect(dateFromIso(isoFromDate(when)), when);
    expect(boolFromInt(intFromBool(true)), isTrue);
    expect(boolFromInt(intFromBool(false)), isFalse);
  });

  group('a store a newer build migrated', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('karmashala-store-newer');
      final db = AppDatabase.open(dir);
      db.execute('PRAGMA user_version = ${db.schemaVersion + 1};');
      db.close();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('is refused by name when asked to refuse', () {
      expect(
        () => AppDatabase.open(dir, refuseNewerSchema: true),
        throwsA(
          isA<StoreSchemaTooNew>().having(
            (e) => e.stored,
            'stored',
            schemaMigrations.keys.reduce((a, b) => a > b ? a : b) + 1,
          ),
        ),
      );
    });

    test('is opened as before when not', () {
      final db = AppDatabase.open(dir);
      addTearDown(db.close);
      expect(db.readMetadata('absent'), isNull);
    });
  });
}
