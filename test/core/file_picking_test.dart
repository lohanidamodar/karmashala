import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/util/file_picking.dart';

/// The freeze itself is out of reach from here: it happens on the platform
/// thread inside `IFileOpenDialog::Show`, and a Dart test has no platform
/// thread to block. What *is* reachable — and is the whole reason
/// `file_picking.dart` exists — is whether the announcement has reached the
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
