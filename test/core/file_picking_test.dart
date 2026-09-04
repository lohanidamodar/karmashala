import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/logging/app_logger.dart';
import 'package:karmashala/src/core/logging/diagnostics.dart';
import 'package:karmashala/src/core/logging/log_file_sink.dart';
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
