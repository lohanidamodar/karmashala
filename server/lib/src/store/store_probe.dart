import 'dart:io';

import 'package:karmashala_store/database.dart';

import '../probe_report.dart';

/// What a store probe found. The caller deploying this host decides what to do
/// about it, so the reasons are separated by **who can fix them**.
enum StoreVerdict {
  /// Opened, migrated and written to.
  ok('STORE OK'),

  /// The bundled library is not beside the executable. Re-deploying fixes it.
  missing('STORE MISSING'),

  /// The library is there and the machine refused it — wrong architecture, a
  /// C library too old, a `noexec` mount. Another copy of the same file will
  /// land in the same place, so the remedy is the machine's, not ours.
  unloadable('STORE UNLOADABLE'),

  /// The library is there and the binary is looking somewhere else: `dart build
  /// cli` writes the bundled library's relative path with the **building**
  /// machine's separator, so a bundle built for one platform on another hunts
  /// for a path that does not exist. Nothing on the machine is wrong and no
  /// upload fixes it — the bundle has to be built on the platform it runs on.
  mislinked('STORE MISLINKED'),

  /// SQLite works; this machine will not hold a database where it was asked to.
  unwritable('STORE UNWRITABLE');

  const StoreVerdict(this.token);

  /// The line the probe prints last. A deployer matches on this, never on prose.
  final String token;
}

/// The library `dart build cli` bundles beside the executable, by platform.
String get bundledLibraryName {
  if (Platform.isWindows) return 'sqlite3.dll';
  if (Platform.isMacOS) return 'libsqlite3.dylib';
  return 'libsqlite3.so';
}

/// Where that library is expected: `bundle/bin/<exe>` looks up to `bundle/lib`.
/// Derived rather than stored, because the bundle can be moved (§20).
File bundledLibrary({String? executable}) {
  final exe = executable ?? Platform.resolvedExecutable;
  final bin = File(exe).parent;
  return File(
    '${bin.parent.path}${Platform.pathSeparator}lib'
    '${Platform.pathSeparator}$bundledLibraryName',
  );
}

/// Asks a deployed host whether it can own a store on this machine: the bundled
/// SQLite loads, the ladder applies, and a real file survives a write. One
/// `ok/FAIL` line each and a verdict token last, so a deployer reads the reason
/// rather than guessing from an exit code.
Future<int> runStoreProbe({IOSink? out, Directory? directory}) async {
  final sink = out ?? stdout;
  void step(String name, bool ok, [String detail = '']) =>
      sink.writeln(probeStep(name, ok, detail));
  // Every failure ends the same way — the token, then 1 — so it is said once.
  int fail(StoreVerdict verdict, String why) {
    sink.writeln('${verdict.token} $why');
    return 1;
  }

  sink.writeln(probeHeader());

  final library = bundledLibrary();

  // The library loads lazily on the first call, so opening *is* the probe.
  // Where it came from is only asserted when it is what failed: a deployed
  // bundle is not the only layout that works, and "ABSENT" above a run that
  // then succeeds is the confident false statement this probe exists to avoid.
  AppDatabase memory;
  try {
    memory = AppDatabase.memory();
  } on Object catch (error) {
    final verdict = classifyOpenFailure('$error', wanted: library);
    step('open in memory', false, '$error');
    sink.writeln(probeNote('store-lib', library.path));
    return fail(verdict, _remedy(verdict, library));
  }

  step('open in memory', true, 'sqlite $sqliteLibraryVersion');
  if (library.existsSync()) sink.writeln(probeNote('store-lib', library.path));

  // The *stored* version against the one this build carries. Comparing
  // `schemaVersion` with the migration map would compare the map with itself.
  final target = memory.schemaVersion;
  final applied = memory.query('PRAGMA user_version;').single['user_version'];
  step('schema ladder', applied == target, 'v$applied of v$target');
  memory.close();
  if (applied != target) {
    return fail(StoreVerdict.unloadable, 'the ladder stopped at v$applied');
  }

  // In-memory proves the library; only a file proves the machine will hold one.
  final where = directory ?? Directory.systemTemp.createTempSync('karmashala');
  final owned = directory == null;
  try {
    final db = AppDatabase.open(where);
    db.writeMetadata('probe', 'karmashala');
    final readBack = db.readMetadata('probe') == 'karmashala';
    step('write round-trip', readBack, 'in ${where.path}');
    // A value, not a check: WAL is asked for and SQLite may decline it (§19).
    sink.writeln(probeNote('journal', db.journalMode));
    db.close();
    if (!readBack) {
      return fail(StoreVerdict.unwritable, 'the value did not survive');
    }
  } on Object catch (error) {
    step('write round-trip', false, '$error');
    return fail(
      StoreVerdict.unwritable,
      '${where.path} cannot hold a database',
    );
  } finally {
    if (owned) {
      try {
        where.deleteSync(recursive: true);
      } on FileSystemException {
        // A probe that cannot tidy up has still answered the question.
      }
    }
  }

  sink.writeln(StoreVerdict.ok.token);
  return 0;
}

/// Which of the three load failures this is. Separated because they need three
/// different responses, and the loader reports all of them as one exception
/// type — only the message says which.
///
/// The discriminator is the **path the loader asked for**, compared against
/// [wanted], the one this build computed. A bundle built for another platform
/// bakes the builder's separator, so the two differ; that is a fact about the
/// artifact rather than a guess about the message, and it reads the same in
/// both directions (a Windows bundle cross-built on Linux fails identically).
StoreVerdict classifyOpenFailure(String error, {required File wanted}) {
  final attempted = RegExp(r"dynamic library '([^']+)'").firstMatch(error);
  if (attempted != null && attempted.group(1) != wanted.path) {
    final asked = attempted.group(1)!;
    // A relative spelling of the same place is not a mismatch; a foreign
    // separator is, and so is a different file altogether.
    if (!wanted.path.endsWith(asked.split(RegExp(r'[\\/]')).last) ||
        asked.contains(_foreignSeparator)) {
      return StoreVerdict.mislinked;
    }
  }
  return wanted.existsSync() ? StoreVerdict.unloadable : StoreVerdict.missing;
}

/// The separator this platform does **not** use, which is the mark a bundle
/// built somewhere else leaves in the path it asks for.
String get _foreignSeparator => Platform.pathSeparator == '/' ? r'\' : '/';

String _remedy(StoreVerdict verdict, File library) => switch (verdict) {
  StoreVerdict.missing =>
    'deploy the host again — ${library.path} is part of the bundle',
  StoreVerdict.unloadable =>
    'the machine refused ${library.path}; check its architecture and libc',
  StoreVerdict.mislinked =>
    'this bundle was built on another platform; build it on the one it runs on',
  // Neither is a load failure, so neither reaches `_remedy`. Spelled out rather
  // than caught by a wildcard, so a new verdict is a compile error here.
  StoreVerdict.ok || StoreVerdict.unwritable => '',
};
