import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/picking.dart';

/// The freeze itself is out of reach from here: it happens on the platform
/// thread inside `IFileOpenDialog::Show`, and a Dart test has no platform
/// thread to block. What *is* reachable — and is the whole reason
/// this library exists — is whether the announcement has reached the
/// **file** by the time the picker is asked for. If it has not, a run that
/// freezes there leaves nothing behind, which is what happened on 2026-09-04
/// and what sent an investigation looking for a crash that never occurred.
void main() {
  late Directory dir;
  late Diagnostics previous;
  late LogFileSink sink;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('karmashala-picker');
    previous = Diagnostics.instance;
    Diagnostics.instance = Diagnostics();
    AppLogger.initialize(onRecord: Diagnostics.instance.handle);
    sink = LogFileSink(directory: dir);
    Diagnostics.instance.attachFile(sink);
    forgetLastPickedDirectory();
  });

  tearDown(() async {
    await sink.close();
    Diagnostics.instance = previous;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String logOnDisk() => sink.file.existsSync() ? sink.file.readAsStringSync() : '';

  test('the file picker is on disk before the picker is shown', () async {
    var logWhenShown = '';

    final chosen = await pickOneFile(
      what: 'an SSH private key',
      show: ({
        List<XTypeGroup> acceptedTypeGroups = const [],
        String? confirmButtonText,
        String? initialDirectory,
      }) async {
        // Where the platform thread would go away for as long as the dialog is
        // up — and, in the reported failure, for good.
        logWhenShown = logOnDisk();
        return XFile(r'C:\Users\someone\.ssh\id_ed25519');
      },
    );

    expect(logWhenShown, contains('opening the file picker'));
    expect(logWhenShown, contains('an SSH private key'));
    expect(chosen?.path, r'C:\Users\someone\.ssh\id_ed25519');
  });

  test('the directory picker is on disk before the picker is shown', () async {
    var logWhenShown = '';

    await pickOneDirectory(
      what: 'a project folder',
      show: ({String? confirmButtonText, String? initialDirectory}) async {
        logWhenShown = logOnDisk();
        return null;
      },
    );

    expect(logWhenShown, contains('opening the directory picker'));
    expect(logWhenShown, contains('a project folder'));
  });

  test('the outcome is logged, and says which button it was', () async {
    await pickOneFile(
      what: 'an image to attach',
      show: ({
        List<XTypeGroup> acceptedTypeGroups = const [],
        String? confirmButtonText,
        String? initialDirectory,
      }) async => null,
    );
    await Diagnostics.instance.flushFile();

    final log = logOnDisk();
    expect(log, contains('opening the file picker for an image to attach'));
    expect(
      log,
      contains('the file picker for an image to attach was dismissed after'),
    );
  });

  group('PickerQuiet', () {
    /// A dialog that holds the isolate the way the measured one did, so a hook
    /// told to be quiet only on a later microtask would not have been told.
    Future<XFile?> Function({
      List<XTypeGroup> acceptedTypeGroups,
      String? confirmButtonText,
      String? initialDirectory,
    })
    occupying(void Function() whileShown) =>
        ({
          List<XTypeGroup> acceptedTypeGroups = const [],
          String? confirmButtonText,
          String? initialDirectory,
        }) async {
          whileShown();
          return null;
        };

    test('registrants are stopped before the dialog and started after', () async {
      final quiet = PickerQuiet();
      final told = <bool>[];
      quiet.register(told.add);
      var toldWhenShown = <bool>[];

      await pickOneFile(
        what: 'a build to install',
        quiet: quiet,
        show: occupying(() => toldWhenShown = [...told]),
      );

      expect(toldWhenShown, [true]);
      expect(told, [true, false]);
      expect(quiet.isQuiet, isFalse);
    });

    test('the directory picker announces to the same registry', () async {
      final quiet = PickerQuiet();
      final told = <bool>[];
      quiet.register(told.add);

      await pickOneDirectory(
        what: 'a project folder',
        quiet: quiet,
        show: ({String? confirmButtonText, String? initialDirectory}) async =>
            null,
      );

      expect(told, [true, false]);
    });

    test('a hook that throws does not hold the picker or the others', () async {
      final quiet = PickerQuiet();
      final told = <bool>[];
      quiet.register((_) => throw StateError('this subsystem is unwell'));
      quiet.register(told.add);

      final chosen = await pickOneFile(
        what: 'a build to install',
        quiet: quiet,
        show: occupying(() {}),
      );

      expect(chosen, isNull);
      expect(told, [true, false]);
    });

    test('unregistering while a picker is up releases that hook', () {
      final quiet = PickerQuiet();
      final told = <bool>[];
      final release = quiet.register(told.add);

      final resume = quiet.begin();
      expect(told, [true]);
      release();
      // Never left stopped by a dialog it will not hear finish.
      expect(told, [true, false]);
      expect(quiet.registered, 0);

      resume();
      expect(told, [true, false]);
    });

    test('registering while a picker is up starts that hook quiet', () {
      final quiet = PickerQuiet();
      final told = <bool>[];
      final resume = quiet.begin();

      quiet.register(told.add);
      expect(told, [true]);

      resume();
      expect(told, [true, false]);
    });

    test('nesting tells each registrant once', () {
      final quiet = PickerQuiet();
      final told = <bool>[];
      quiet.register(told.add);

      final outer = quiet.begin();
      final inner = quiet.begin();
      expect(told, [true]);

      inner();
      expect(told, [true], reason: 'a picker is still up');
      inner();
      outer();
      expect(told, [true, false]);
    });
  });

  group('where a picker starts', () {
    /// A disk with exactly these directories on it.
    DirectoryProbe only(Set<String> live) => live.contains;

    const env = {'USERPROFILE': r'C:\Users\someone', 'SystemDrive': 'C:'};

    test("the caller's own folder wins when it is there", () {
      expect(
        pickerStartDirectory(
          r'C:\src\karmashala',
          probe: only({r'C:\src\karmashala', r'C:\Users\someone'}),
          environment: env,
        ),
        r'C:\src\karmashala',
      );
    });

    test('a file resolves to the folder holding it', () {
      expect(
        pickerStartDirectory(
          r'C:\Tools\flutter\bin\flutter.bat',
          probe: only({r'C:\Tools\flutter\bin', r'C:\Users\someone'}),
          environment: env,
        ),
        r'C:\Tools\flutter\bin',
      );
    });

    test('a trailing separator does not lose the folder', () {
      expect(
        pickerStartDirectory(
          'C:\\src\\karmashala\\',
          probe: only({r'C:\src\karmashala'}),
          environment: env,
        ),
        r'C:\src\karmashala',
      );
    });

    // The whole point: this is what the shell was restoring on its own, and
    // drawing it costs 30 s because the dialog must enumerate Network first.
    for (final refused in [
      r'\\wsl.localhost\archlinux\home\dlohani\projects\appwrite-ai-workdir',
      r'\\wsl$\archlinux\home\dlohani',
      r'\\fileserver\share\builds',
      '//fileserver/share/builds',
    ]) {
      test('refuses $refused even when it answers', () {
        expect(
          pickerStartDirectory(
            refused,
            // A probe that says yes to everything: refusal is by spelling,
            // before anything stats it.
            probe: (_) => true,
            environment: env,
          ),
          r'C:\Users\someone',
        );
      });
    }

    test('a refused folder is not even stat-ed', () {
      final asked = <String>[];
      pickerStartDirectory(
        r'\\wsl.localhost\archlinux\home\dlohani',
        probe: (path) {
          asked.add(path);
          return true;
        },
        environment: env,
      );
      expect(
        asked,
        isNot(contains(anyOf(contains('wsl'), startsWith(r'\\')))),
        reason: 'the stat is itself the thing that blocks',
      );
    });

    test('a dead folder falls through to the profile', () {
      expect(
        pickerStartDirectory(
          r'D:\gone',
          probe: only({r'C:\Users\someone'}),
          environment: env,
        ),
        r'C:\Users\someone',
      );
    });

    test('a probe that throws is a refusal, not a crash', () {
      expect(
        pickerStartDirectory(
          r'C:\junction',
          probe: (path) {
            if (path == r'C:\junction') throw const FileSystemException('448');
            return path == r'C:\Users\someone';
          },
          environment: env,
        ),
        r'C:\Users\someone',
      );
    });

    test('HOME answers when there is no USERPROFILE', () {
      expect(
        pickerStartDirectory(
          null,
          probe: only({'/home/someone'}),
          environment: const {'HOME': '/home/someone'},
        ),
        '/home/someone',
      );
    });

    test('with nothing live it still never answers null or a UNC', () {
      final floor = pickerStartDirectory(
        r'\\wsl.localhost\archlinux\home',
        probe: (_) => false,
        environment: env,
      );
      expect(floor, r'C:\');
      expect(floor, isNot(startsWith(r'\\')));
    });

    test('a directory picker remembers where it landed', () async {
      final home = Directory.systemTemp.createTempSync('karmashala-start');
      addTearDown(() => home.deleteSync(recursive: true));

      await pickOneDirectory(
        what: 'a project folder',
        show: ({String? confirmButtonText, String? initialDirectory}) async =>
            home.path,
      );
      expect(lastPickedDirectory, home.path);

      // The next picker has no idea of its own, and opens there rather than
      // wherever the shell was last.
      String? opened;
      await pickOneDirectory(
        what: 'somewhere else',
        show: ({String? confirmButtonText, String? initialDirectory}) async {
          opened = initialDirectory;
          return null;
        },
      );
      expect(opened, home.path);
    });

    test('a file picker remembers the folder, not the file', () async {
      final home = Directory.systemTemp.createTempSync('karmashala-start');
      final file = File('${home.path}${Platform.pathSeparator}chosen.exe')
        ..writeAsStringSync('');
      addTearDown(() => home.deleteSync(recursive: true));

      await pickOneFile(
        what: 'a terminal program',
        show: ({
          List<XTypeGroup> acceptedTypeGroups = const [],
          String? confirmButtonText,
          String? initialDirectory,
        }) async => XFile(file.path),
      );

      expect(lastPickedDirectory, home.path);
    });

    test('the shell is always given a folder, and the log names it', () async {
      String? opened;
      await pickOneFile(
        what: 'an agent executable',
        startNear: r'\\wsl.localhost\archlinux\home\dlohani',
        probe: only({r'C:\Users\someone'}),
        environment: env,
        show: ({
          List<XTypeGroup> acceptedTypeGroups = const [],
          String? confirmButtonText,
          String? initialDirectory,
        }) async {
          opened = initialDirectory;
          return null;
        },
      );
      await Diagnostics.instance.flushFile();

      expect(opened, r'C:\Users\someone');
      // The log redacts the user's own name, so the line is asserted up to it.
      expect(
        logOnDisk(),
        contains(
          r'opening the file picker for an agent executable, '
          r'starting at C:\Users\',
        ),
      );
    });
  });

  group('no picker in lib may leave the folder to the shell', () {
    /// [source] with every comment and string literal blanked, so an
    /// apostrophe in a comment cannot open a string that never closes and a
    /// bracket in a message cannot unbalance the argument list.
    String codeOnly(String source) {
      final out = List<String>.filled(source.length, ' ');
      var i = 0;
      while (i < source.length) {
        final c = source[i];
        final next = i + 1 < source.length ? source[i + 1] : '';
        if (c == '/' && next == '/') {
          while (i < source.length && source[i] != '\n') {
            i++;
          }
          continue;
        }
        if (c == '/' && next == '*') {
          final end = source.indexOf('*/', i + 2);
          i = end == -1 ? source.length : end + 2;
          continue;
        }
        if (c == "'" || c == '"') {
          final triple = source.startsWith(c * 3, i);
          final close = triple ? c * 3 : c;
          i += close.length;
          while (i < source.length) {
            if (!triple && source[i] == r'\') {
              i += 2;
              continue;
            }
            if (source.startsWith(close, i)) {
              i += close.length;
              break;
            }
            i++;
          }
          continue;
        }
        out[i] = c;
        i++;
      }
      return out.join();
    }

    /// The argument list of every `name(` call in [code].
    List<String> argumentsOf(String code, String name) {
      final found = <String>[];
      final needle = '$name(';
      var at = code.indexOf(needle);
      while (at != -1) {
        var i = at + needle.length;
        final start = i;
        var depth = 1;
        while (i < code.length && depth > 0) {
          if (code[i] == '(') depth++;
          if (code[i] == ')') depth--;
          i++;
        }
        found.add(code.substring(start, i > start ? i - 1 : start));
        at = code.indexOf(needle, i);
      }
      return found;
    }

    /// Every `lib/` of ours: the app's and each workspace member's. This
    /// suite runs from `packages/karmashala_ui`, and scanning only its own
    /// `lib` would leave the guard reading the file that defines the picker
    /// and nothing that calls it.
    List<Directory> everyLib() {
      final repository = Directory('../..');
      expect(
        Directory('${repository.path}/lib').existsSync(),
        isTrue,
        reason: 'run from packages/karmashala_ui',
      );
      return [
        Directory('${repository.path}/lib'),
        for (final member
            in Directory('${repository.path}/packages').listSync().whereType<
              Directory
            >())
          if (Directory('${member.path}/lib').existsSync())
            Directory('${member.path}/lib'),
      ];
    }

    test('every call names where it starts', () {
      final silent = <String>[];
      for (final root in everyLib()) {
        for (final file in root.listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          final where = file.path.replaceAll(r'\', '/');
          // The definitions themselves, whose parameter list is not a call.
          if (where.endsWith('karmashala_ui/lib/src/file_picking.dart')) {
            continue;
          }
          final code = codeOnly(file.readAsStringSync());
          for (final name in ['pickOneFile', 'pickOneDirectory']) {
            for (final arguments in argumentsOf(code, name)) {
              if (!arguments.contains('startNear:')) {
                silent.add('$where — $name');
              }
            }
          }
        }
      }

      expect(
        silent,
        isEmpty,
        reason:
            'a picker with no startNear lets the shell restore its own last '
            'folder, which on the reporting machine cost 30 s',
      );
    });

    test('the sweep reaches the app and the packages, not just this one', () {
      final roots = everyLib().map((d) => d.path.replaceAll(r'\', '/'));
      expect(roots, contains(endsWith('/lib')));
      expect(roots.length, greaterThan(5));
      expect(
        roots.any((r) => r.contains('packages/karmashala_devices')),
        isTrue,
        reason: 'the device pane holds three of the pickers',
      );
    });

    test('the scanner finds a call it should and reads its arguments', () {
      const sample = """
        // pickOneFile( isn't a call, and platforms' apostrophe is not a string
        final a = await pickOneFile(what: 'x (y)', startNear: dir(1));
        final b = await pickOneDirectory(what: 'z');
      """;
      final code = codeOnly(sample);
      expect(argumentsOf(code, 'pickOneFile'), hasLength(1));
      expect(argumentsOf(code, 'pickOneFile').single, contains('startNear:'));
      expect(
        argumentsOf(code, 'pickOneDirectory').single,
        isNot(contains('startNear:')),
      );
    });
  });

  test('a host that refuses the picker is logged, not thrown', () async {
    final chosen = await pickOneFile(
      what: 'a terminal program',
      show: ({
        List<XTypeGroup> acceptedTypeGroups = const [],
        String? confirmButtonText,
        String? initialDirectory,
      }) async => throw MissingPluginException('no file_selector here'),
    );
    await Diagnostics.instance.flushFile();

    expect(chosen, isNull);
    expect(
      logOnDisk(),
      contains('the file picker for a terminal program failed after'),
    );
  });
}
