import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// Collects what the probe printed, so a test reads the reason a deployer would
/// read and not only the exit code.
class _Lines implements IOSink {
  final lines = <String>[];

  String get text => lines.join('\n');

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('the bundled library is found where the bundle puts it', () {
    final sep = Platform.pathSeparator;

    test('one directory up from bin/, then into lib/', () {
      final library = bundledLibrary(
        executable: [
          '',
          'opt',
          'karmashala',
          'bin',
          'karmashala_host',
        ].join(sep),
      );

      expect(
        library.path,
        ['', 'opt', 'karmashala', 'lib', bundledLibraryName].join(sep),
      );
    });

    test('the name is this platform\'s, not one baked in', () {
      expect(
        bundledLibraryName,
        Platform.isWindows
            ? 'sqlite3.dll'
            : Platform.isMacOS
            ? 'libsqlite3.dylib'
            : 'libsqlite3.so',
      );
    });
  });

  group('a machine that can hold a store', () {
    test('says so, and names the sqlite it actually got', () async {
      final out = _Lines();
      final where = Directory.systemTemp.createTempSync('probe-ok');
      addTearDown(() => where.deleteSync(recursive: true));

      final code = await runStoreProbe(out: out, directory: where);

      expect(code, 0);
      expect(out.lines.last, StoreVerdict.ok.token);
      expect(out.text, contains('ok   open in memory'));
      expect(out.text, contains('ok   schema ladder'));
      expect(out.text, contains('ok   write round-trip'));
      expect(out.text, contains('sqlite 3.'));
    });

    test('a handed directory is not the probe\'s to delete', () async {
      final where = Directory.systemTemp.createTempSync('probe-keep');
      addTearDown(() => where.deleteSync(recursive: true));

      await runStoreProbe(out: _Lines(), directory: where);

      expect(where.existsSync(), isTrue);
      expect(
        where.listSync().map((e) => e.uri.pathSegments.last),
        contains('karmashala.sqlite'),
      );
    });
  });

  group('a machine that will not hold one', () {
    test('blames the directory, not sqlite', () async {
      final out = _Lines();
      final root = Directory.systemTemp.createTempSync('probe-bad');
      addTearDown(() => root.deleteSync(recursive: true));
      // A directory below a *file* is one no machine will open a database in.
      final occupied = File('${root.path}${Platform.pathSeparator}occupied')
        ..writeAsStringSync('not a directory');

      final code = await runStoreProbe(
        out: out,
        directory: Directory('${occupied.path}${Platform.pathSeparator}within'),
      );

      expect(code, 1);
      expect(out.lines.last, startsWith(StoreVerdict.unwritable.token));
      expect(
        out.text,
        contains('ok   open in memory'),
        reason: 'the library loaded; only the disk refused',
      );
    });
  });

  test('the verdicts separate who can fix them', () {
    // A deployer matches on these, so they are pinned rather than inferred.
    expect(StoreVerdict.ok.token, 'STORE OK');
    expect(StoreVerdict.missing.token, 'STORE MISSING');
    expect(StoreVerdict.unloadable.token, 'STORE UNLOADABLE');
    expect(StoreVerdict.mislinked.token, 'STORE MISLINKED');
    expect(StoreVerdict.unwritable.token, 'STORE UNWRITABLE');
  });

  group('classifying a load failure', () {
    // Measured 2026-09-15: what a Linux bundle cross-compiled on Windows says.
    const crossCompiled =
        r"Invalid argument(s): Couldn't resolve native function "
        r"'sqlite3_initialize' in 'package:sqlite3/src/ffi/libsqlite3.g.dart' : "
        r"Failed to load dynamic library '..\lib\libsqlite3.so' relative to "
        r"'/opt/karmashala/bin/karmashala_host': "
        r"/opt/karmashala/bin/..\lib\libsqlite3.so: cannot open shared object "
        r'file: No such file or directory.';

    // The library really is there; the binary is asking for somewhere else.
    final present = File(
      '${Directory.systemTemp.createTempSync('lib').path}/l',
    );
    setUpAll(() => present.writeAsStringSync('a library'));
    tearDownAll(() => present.parent.deleteSync(recursive: true));

    test(
      'a path that is not the one we computed is the build, not the machine',
      () {
        expect(
          classifyOpenFailure(crossCompiled, wanted: present),
          StoreVerdict.mislinked,
          reason: 'the file is present, so this must not read as a refusal',
        );
      },
    );

    test('and it reads the same in the other direction', () {
      // A Windows bundle cross-built on Linux bakes the other separator. The
      // phenomenon is symmetric, so the classifier must be too.
      const builtOnLinuxForWindows =
          r"Invalid argument(s): Failed to load dynamic library "
          r"'../lib/sqlite3.dll' relative to 'C:\karmashala\bin\karmashala_host.exe'";

      expect(
        classifyOpenFailure(builtOnLinuxForWindows, wanted: present),
        StoreVerdict.mislinked,
      );
    });

    test('an absent library is another deploy', () {
      final absent = File('${present.parent.path}/not-here');

      expect(
        classifyOpenFailure(
          'cannot open shared object file: No such file or directory',
          wanted: absent,
        ),
        StoreVerdict.missing,
      );
    });

    test('a present library the loader rejected is the machine\'s', () {
      expect(
        classifyOpenFailure('wrong ELF class: ELFCLASS32', wanted: present),
        StoreVerdict.unloadable,
      );
      expect(
        classifyOpenFailure("version `GLIBC_2.34' not found", wanted: present),
        StoreVerdict.unloadable,
      );
    });

    test('the very path we asked for is the machine refusing it', () {
      expect(
        classifyOpenFailure(
          "Failed to load dynamic library '${present.path}': wrong ELF class",
          wanted: present,
        ),
        StoreVerdict.unloadable,
        reason: 'same path, so the build is not what is wrong',
      );
    });
  });
}
