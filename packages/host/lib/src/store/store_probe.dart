import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';

/// What a store probe found. The caller deploying this host decides what to do
/// about it, so the reasons are separated by **who can fix them**: a missing
/// library is another upload, and an unloadable one never is.
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
  /// machine's separator, so a Linux bundle cross-compiled on Windows hunts for
  /// `..\lib\libsqlite3.so`. Nothing on the machine is wrong and no upload
  /// fixes it — the bundle has to be built on the platform it runs on.
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
  void step(String name, bool ok, [String detail = '']) {
    sink.writeln(
      '${ok ? 'ok  ' : 'FAIL'} $name${detail.isEmpty ? '' : '  $detail'}',
    );
  }

  sink.writeln('host      ${Platform.operatingSystem} ${_arch()}');

  final library = bundledLibrary();

  // The library loads lazily on the first call, so opening *is* the probe.
  // Where it came from is only asserted when it is what failed: a deployed
  // bundle is not the only layout that works, and "ABSENT" above a run that
  // then succeeds is the confident false statement this probe exists to avoid.
  AppDatabase memory;
  try {
    memory = AppDatabase.memory();
  } on Object catch (error) {
    final verdict = classifyOpenFailure(
      '$error',
      libraryPresent: library.existsSync(),
    );
    step('open in memory', false, '$error');
    sink.writeln('store-lib ${library.path}');
    sink.writeln('${verdict.token} ${_remedy(verdict, library)}');
    return 1;
  }

  step('open in memory', true, 'sqlite $sqliteLibraryVersion');
  if (library.existsSync()) sink.writeln('store-lib ${library.path}');

  final highest = schemaMigrations.keys.reduce((a, b) => a > b ? a : b);
  final applied = memory.schemaVersion == highest;
  step('schema ladder', applied, 'v${memory.schemaVersion} of v$highest');
  memory.close();
  if (!applied) {
    sink.writeln('${StoreVerdict.unloadable.token} the ladder did not apply');
    return 1;
  }

  // In-memory proves the library; only a file proves the machine will hold one.
  final where = directory ?? Directory.systemTemp.createTempSync('karmashala');
  final owned = directory == null;
  try {
    final db = AppDatabase.open(where);
    db.writeMetadata('probe', 'karmashala');
    final readBack = db.readMetadata('probe') == 'karmashala';
    step('write round-trip', readBack, 'in ${where.path}');
    step('journal mode', true, db.journalMode);
    db.close();
    if (!readBack) {
      sink.writeln(
        '${StoreVerdict.unwritable.token} the value did not survive',
      );
      return 1;
    }
  } on Object catch (error) {
    step('write round-trip', false, '$error');
    sink.writeln(
      '${StoreVerdict.unwritable.token} ${where.path} cannot hold a database',
    );
    return 1;
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
/// different responses, and only the message can tell them apart: the loader
/// reports all of them as the same exception type.
StoreVerdict classifyOpenFailure(String error, {required bool libraryPresent}) {
  // A path with the other platform's separator did not come from this machine.
  // Checked before presence: the file *is* there, which would otherwise read as
  // the machine refusing a library it was never asked for.
  if (Platform.pathSeparator == '/' && error.contains(r'\lib\')) {
    return StoreVerdict.mislinked;
  }
  return libraryPresent ? StoreVerdict.unloadable : StoreVerdict.missing;
}

String _remedy(StoreVerdict verdict, File library) => switch (verdict) {
  StoreVerdict.missing =>
    'deploy the host again — ${library.path} is part of the bundle',
  StoreVerdict.unloadable =>
    'the machine refused ${library.path}; check its architecture and libc',
  StoreVerdict.mislinked =>
    'this bundle was built on another platform; build it on the one it runs on',
  _ => '',
};

String _arch() {
  final match = RegExp(r'"[a-z]+_([a-z0-9]+)"').firstMatch(Platform.version);
  return match?.group(1) ?? 'unknown';
}
