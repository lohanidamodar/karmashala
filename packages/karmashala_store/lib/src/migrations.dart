import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

part 'migrations/migrations_v01_v19.dart';
part 'migrations/migrations_v20_v39.dart';
part 'migrations/migrations_v40_up.dart';

/// SQL applied to move the database to the keyed version. Hand-written and
/// idempotent at the DDL level (`IF NOT EXISTS`), so a re-run is safe.
typedef MigrationStep = void Function(Database db);

/// Ordered schema migrations, keyed by the target `user_version`. Every step
/// above the stored `PRAGMA user_version` runs in order, one transaction each.
final Map<int, MigrationStep> schemaMigrations = {
  1: _migrateToV1,
  2: _migrateToV2,
  3: _migrateToV3,
  4: _migrateToV4,
  5: _migrateToV5,
  6: _migrateToV6,
  7: _migrateToV7,
  8: _migrateToV8,
  9: _migrateToV9,
  10: _migrateToV10,
  11: _migrateToV11,
  12: _migrateToV12,
  13: _migrateToV13,
  14: _migrateToV14,
  15: _migrateToV15,
  16: _migrateToV16,
  17: _migrateToV17,
  18: _migrateToV18,
  19: _migrateToV19,
  20: _migrateToV20,
  21: _migrateToV21,
  22: _migrateToV22,
  23: _migrateToV23,
  24: _migrateToV24,
  25: _migrateToV25,
  26: _migrateToV26,
  27: _migrateToV27,
  28: _migrateToV28,
  29: _migrateToV29,
  30: _migrateToV30,
  31: _migrateToV31,
  32: _migrateToV32,
  33: _migrateToV33,
  34: _migrateToV34,
  35: _migrateToV35,
  36: _migrateToV36,
  37: _migrateToV37,
  38: _migrateToV38,
  39: _migrateToV39,
  40: _migrateToV40,
  41: _migrateToV41,
  42: _migrateToV42,
  43: _migrateToV43,
  44: _migrateToV44,
  45: _migrateToV45,
  46: _migrateToV46,
  47: _migrateToV47,
  48: _migrateToV48,
  49: _migrateToV49,
  50: _migrateToV50,
  51: _migrateToV51,
  52: _migrateToV52,
  53: _migrateToV53,
  54: _migrateToV54,
  55: _migrateToV55,
  56: _migrateToV56,
  57: _migrateToV57,
  58: _migrateToV58,
  59: _migrateToV59,
  60: _migrateToV60,
  61: _migrateToV61,
  62: _migrateToV62,
  63: _migrateToV63,
  64: _migrateToV64,
};
