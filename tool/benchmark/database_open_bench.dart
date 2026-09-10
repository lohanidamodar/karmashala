import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:sqlite3/sqlite3.dart';

/// Benchmark — NOT part of `flutter test`'s default run. Run it on demand:
///
///   flutter test tool/benchmark/database_open_bench.dart
///
/// What one `AppDatabase.memory()` costs, split into the bare `sqlite3` handle,
/// the connection pragmas and the migration ladder — and what the same schema
/// costs when it is cloned from a template with `Database.backup` instead —
/// the clone having been proposed as a gate-time lever. 350 suites open one.
void main() {
  const samples = 60;
  const warmup = 5;

  Duration median(List<Duration> xs) {
    xs.sort();
    return xs[xs.length ~/ 2];
  }

  String ms(Duration d) => '${(d.inMicroseconds / 1000).toStringAsFixed(2)} ms';

  Duration bench(void Function() body) {
    for (var i = 0; i < warmup; i++) {
      body();
    }
    final taken = <Duration>[];
    for (var i = 0; i < samples; i++) {
      final sw = Stopwatch()..start();
      body();
      sw.stop();
      taken.add(sw.elapsed);
    }
    return median(taken);
  }

  /// The pragma sequence `AppDatabase._configure` applies, replicated so the
  /// benchmark can price it apart from the ladder.
  void configure(Database db) {
    db.execute('PRAGMA foreign_keys = ON;');
    try {
      db.execute('PRAGMA journal_mode = WAL;');
    } on SqliteException {
      return;
    }
    final mode =
        (db.select('PRAGMA journal_mode;').first.values.first! as String)
            .toLowerCase();
    if (mode != 'wal') return;
    db.execute('PRAGMA synchronous = NORMAL;');
  }

  void ladder(Database db) {
    final versions = schemaMigrations.keys.toList()..sort();
    for (final version in versions) {
      db.execute('BEGIN;');
      schemaMigrations[version]!(db);
      db.execute('PRAGMA user_version = $version;');
      db.execute('COMMIT;');
    }
  }

  test('AppDatabase.memory(): where the time goes', () {
    // Before anything else in this isolate has touched sqlite3 or the migration
    // closures — what a suite's *first* open pays, and no template can avoid.
    final coldWatch = Stopwatch()..start();
    AppDatabase.memory().close();
    coldWatch.stop();
    final cold = coldWatch.elapsed;

    final bare = bench(() => sqlite3.openInMemory().close());

    final configured = bench(() {
      final db = sqlite3.openInMemory();
      configure(db);
      db.close();
    });

    final full = bench(() => AppDatabase.memory().close());

    final template = sqlite3.openInMemory();
    configure(template);
    ladder(template);
    final cloned = bench(() {
      final db = sqlite3.openInMemory();
      template.backup(db).drain<void>();
      configure(db);
      db.close();
    });
    final pageCount = template.select('PRAGMA page_count;').first.values.first!;
    final pageSize = template.select('PRAGMA page_size;').first.values.first!;
    template.close();

    final highest = schemaMigrations.keys.reduce((a, b) => a > b ? a : b);
    final saved = full - cloned;
    // ignore: avoid_print
    print(
      'AppDatabase.memory(), median of $samples '
      '(${schemaMigrations.length} migrations, v$highest)\n'
      '  cold first open       ${ms(cold)}  (JIT + ladder, once per isolate)\n'
      '  bare openInMemory     ${ms(bare)}\n'
      '  + connection pragmas  ${ms(configured)}  '
      '(pragmas ${ms(configured - bare)})\n'
      '  + migration ladder    ${ms(full)}  (ladder ${ms(full - configured)})\n'
      '  clone from template   ${ms(cloned)}  (saves ${ms(saved)}, '
      '${(100 * saved.inMicroseconds / full.inMicroseconds).toStringAsFixed(1)}%)\n'
      '  schema size           $pageCount pages x $pageSize B = '
      '${((pageCount as int) * (pageSize as int) / 1024).toStringAsFixed(0)} KiB',
    );

    expect(full.inMicroseconds, greaterThan(0));
    expect(cloned.inMicroseconds, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
