import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/gradle_project.dart';
import '../domain/project_detection.dart';

/// Reads the handful of files a project kind is decided by, in that
/// checkout's own environment, and hands the text to the pure decision.
///
/// **The same split as `FlutterProjectScanner`, for the same reason.** The
/// local host is read with `dart:io`, which costs no subprocess; a
/// distribution or another machine is read through the [CommandRunner] that
/// environment already has, because there is nothing else that can see it.
/// Both feed one `detectProject`.
///
/// **It runs when someone asks.** Nothing here is on a timer: a detection
/// costs a few reads locally and a few round trips over SSH, so the answer
/// carries the time it was taken and is re-taken on demand (§19).
class ProjectScanner {
  ProjectScanner({required this.runner, required this.kind});

  final CommandRunner runner;
  final EnvironmentKind kind;

  p.Context get _context => usesWindowsPaths(kind) ? p.windows : p.posix;

  /// What kind of project sits at [directory] — and, when none does, the
  /// specific reason where there is one.
  ///
  /// Both come out of the same file map, so the refusal cannot describe a
  /// directory other than the one that was read.
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
