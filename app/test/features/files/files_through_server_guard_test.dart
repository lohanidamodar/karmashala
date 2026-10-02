/// Slice 3c's guard: the app reads no machine's files itself. The file pane,
/// the editor and Quick Open go through the server; the app carries only
/// `karmashala_files`' values, never its spaces.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The files in those features that still touch this machine's own disk or
/// platform, and why: an external editor launched here, a server file brought
/// here to open with its default app, the health command's wording, and the
/// media viewer's playback cache — a remote video or audio file read through
/// the server and copied here, because the player needs a local path.
const _dartIoAllowed = {
  'lib/src/features/editor/data/code_editor_service.dart',
  'lib/src/features/editor/data/media_store.dart',
  'lib/src/features/files/application/server_file_opening.dart',
  'lib/src/app/shell/quick_open/quick_open_sources.dart',
};

Iterable<File> _dartFiles(String under) => Directory(under)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _relative(File file) =>
    p.relative(file.path, from: Directory.current.path).replaceAll(r'\', '/');

void main() {
  test('nothing in the app imports the file spaces, only their values', () {
    final offenders = [
      for (final file in _dartFiles('lib'))
        if (file.readAsStringSync().contains(
          'package:karmashala_files/karmashala_files.dart',
        ))
          _relative(file),
    ];
    expect(offenders, isEmpty);
  });

  test('the file pane, the editor and Quick Open read no disk themselves', () {
    final offenders = [
      for (final dir in [
        'lib/src/features/files',
        'lib/src/features/file_explorer',
        'lib/src/features/editor',
        'lib/src/app/shell/quick_open',
      ])
        for (final file in _dartFiles(dir))
          if (file.readAsStringSync().contains("import 'dart:io'") &&
              !_dartIoAllowed.contains(_relative(file)))
            _relative(file),
    ];
    expect(offenders, isEmpty);
  });

  test('every allowed exception still exists and still needs it', () {
    for (final path in _dartIoAllowed) {
      expect(
        File(path).readAsStringSync(),
        contains("import 'dart:io'"),
        reason: '$path no longer needs its place on the list',
      );
    }
  });
}
