import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../domain/gradle_project.dart';
import '../domain/project_detection.dart';

/// Reads the files a project kind is decided by, in that checkout's own
/// environment: `dart:io` locally, a [CommandRunner] elsewhere, and only on ask.
class ProjectScanner {
  ProjectScanner({required this.runner, required this.kind});

  final CommandRunner runner;
  final EnvironmentKind kind;

  p.Context get _context => usesWindowsPaths(kind) ? p.windows : p.posix;

  /// What kind of project sits at [directory], and the specific reason when
  /// none does — both off one file map, so the refusal names the right one.
  Future<({ProjectReading? project, String? note})> readAt(
    EnvironmentPath directory,
  ) async {
    final files = <String, String>{};
    for (final relative in kProjectRootFiles) {
      final contents = await readFile(directory, relative);
      if (contents != null) files[relative] = contents;
    }

    // A second round, because which module scripts to read is a question only
    // the settings script can answer.
    final settings =
        files['settings.gradle.kts'] ?? files['settings.gradle'] ?? '';
    for (final relative in gradleModuleScriptPaths(
      gradleIncludedModules(settings),
    )) {
      final contents = await readFile(directory, relative);
      if (contents != null) files[relative] = contents;
    }

    final entries = <String, List<String>>{
      '': await listEntries(directory, ''),
    };
    // A third round, for the schemes inside whichever Xcode project is here.
    for (final name in entries['']!) {
      if (!name.endsWith('.xcodeproj') && !name.endsWith('.xcworkspace')) {
        continue;
      }
      final schemes = '$name/xcshareddata/xcschemes';
      entries[schemes] = await listEntries(directory, schemes);
    }

    String? read(String relative) => files[relative];
    final project = detectProject(
      directoryName: _context.basename(directory.path),
      read: read,
      list: (String relative) => entries[relative] ?? const <String>[],
    );
    return (
      project: project,
      note: project == null ? notAProjectNote(read: read) : null,
    );
  }

  /// [relative] as an absolute path in this environment's own spelling — what
  /// `device_install_app` takes.
  String absolutePathOf(EnvironmentPath directory, String relative) =>
      _join(directory.path, relative);

  /// One file's text, or **null when it is not there or could not be read** —
  /// which is not an empty file.
  Future<String?> readFile(EnvironmentPath directory, String relative) async {
    final path = _join(directory.path, relative);
    if (isLocalHost(kind)) {
      final file = File(path);
      if (!file.existsSync()) return null;
      try {
        return file.readAsStringSync();
      } on FileSystemException {
        return null;
      }
    }
    try {
      final result = await runner.run(
        CommandRequest(executable: 'cat', arguments: <String>[path]),
      );
      return result.ok ? result.stdout : null;
    } on CommandException {
      return null;
    }
  }

  /// The entry names directly inside [relative], or empty when there are none
  /// to read.
  Future<List<String>> listEntries(
    EnvironmentPath directory,
    String relative,
  ) async {
    final path = _join(directory.path, relative);
    if (isLocalHost(kind)) {
      try {
        return <String>[
          for (final entry in Directory(path).listSync(followLinks: false))
            _context.basename(entry.path),
        ];
      } on FileSystemException {
        return const <String>[];
      }
    }
    try {
      final result = await runner.run(
        CommandRequest(executable: 'ls', arguments: <String>['-1', path]),
      );
      if (!result.ok) return const <String>[];
      return <String>[
        for (final line in result.stdout.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];
    } on CommandException {
      return const <String>[];
    }
  }

  /// Joins a forward-slash relative path — including a leading `..` — onto an
  /// absolute one in this environment's own spelling.
  String _join(String root, String relative) {
    if (relative.isEmpty) return root;
    return _context.normalize(
      _context.joinAll(<String>[root, ...relative.split('/')]),
    );
  }
}
