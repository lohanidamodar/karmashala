import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import '../domain/flutter_project.dart';

/// Directory names never worth descending into: they hold *copies* of
/// pubspecs, and a dot directory may be a sibling checkout's worktree.
const Set<String> kFlutterScanSkips = <String>{
  'build',
  'ios',
  'android',
  'linux',
  'macos',
  'windows',
  'web',
};

/// Finds the Flutter projects in one checkout, in that checkout's own
/// environment: `dart:io` for the local host, the [CommandRunner] for anything
/// else. Runs when someone asks — never on a timer (§19).
class FlutterProjectScanner {
  FlutterProjectScanner({required this.runner, required this.kind});

  final CommandRunner runner;
  final EnvironmentKind kind;

  p.Context get _context => usesWindowsPaths(kind) ? p.windows : p.posix;

  /// The Flutter projects at or under [root].
  Future<List<FlutterProject>> scan(
    EnvironmentPath root, {
    int maxDepth = kFlutterProjectMaxDepth,
  }) async {
    final candidates = isLocalHost(kind)
        ? await _readLocally(root.path, maxDepth)
        : await _readOverRunner(root, maxDepth);
    return flutterProjectsIn(
      root: root.path,
      candidates: candidates,
      context: _context,
      maxDepth: maxDepth,
    );
  }

  /// The project **at** [directory], or null when that directory is not one.
  Future<FlutterProject?> projectAt(EnvironmentPath directory) async {
    final found = await scan(directory, maxDepth: 0);
    return found.isEmpty ? null : found.single;
  }

  /// Whether `pub get` has been run in [directory] — or **null when that could
  /// not be established**, which is not false (§19). The `package_config.json`
  /// rather than `.dart_tool/`: other things create the directory.
  Future<bool?> hasPackageConfig(EnvironmentPath directory) async {
    final path = _context.join(
      directory.path,
      '.dart_tool',
      'package_config.json',
    );
    if (isLocalHost(kind)) return File(path).existsSync();
    try {
      final result = await runner.run(
        CommandRequest(executable: 'test', arguments: <String>['-f', path]),
      );
      return result.exitCode == 0;
    } on CommandException {
      return null;
    }
  }

  /// This machine's own disk, walked breadth-first and stopped at [maxDepth].
  Future<List<PubspecCandidate>> _readLocally(String root, int maxDepth) async {
    final found = <PubspecCandidate>[];
    var level = <String>[root];
    for (var depth = 0; depth <= maxDepth; depth++) {
      final next = <String>[];
      for (final directory in level) {
        final pubspec = File(_context.join(directory, 'pubspec.yaml'));
        if (pubspec.existsSync()) {
          try {
            found.add((
              path: pubspec.path,
              contents: pubspec.readAsStringSync(),
            ));
          } on FileSystemException {
            // Unreadable is not a project we can offer, nor a failed scan.
          }
        }
        if (depth == maxDepth) continue;
        try {
          for (final entry in Directory(
            directory,
          ).listSync(followLinks: false)) {
            if (entry is! Directory) continue;
            final name = _context.basename(entry.path);
            if (name.startsWith('.') || kFlutterScanSkips.contains(name)) {
              continue;
            }
            next.add(entry.path);
          }
        } on FileSystemException {
          // An unreadable directory contributes nothing and stops nothing.
        }
      }
      level = next;
      if (level.isEmpty) break;
    }
    return found;
  }

  /// A distribution or another machine, asked once for the list and once per
  /// file for the text.
  ///
  /// `-maxdepth` counts the pubspec itself, so a project [maxDepth]
  /// directories down is `maxDepth + 1` path components below the root.
  Future<List<PubspecCandidate>> _readOverRunner(
    EnvironmentPath root,
    int maxDepth,
  ) async {
    final CommandResult listing;
    try {
      listing = await runner.run(
        CommandRequest(
          executable: 'find',
          arguments: <String>[
            root.path,
            '-maxdepth',
            '${maxDepth + 1}',
            '-name',
            'pubspec.yaml',
            '-not',
            '-path',
            '*/.*',
            for (final skip in kFlutterScanSkips) ...<String>[
              '-not',
              '-path',
              '*/$skip/*',
            ],
          ],
        ),
      );
    } on CommandException {
      return const <PubspecCandidate>[];
    }
    if (!listing.ok) return const <PubspecCandidate>[];

    final found = <PubspecCandidate>[];
    for (final line in listing.stdout.split('\n')) {
      final path = line.trim();
      if (path.isEmpty) continue;
      try {
        final text = await runner.run(
          CommandRequest(executable: 'cat', arguments: <String>[path]),
        );
        if (text.ok) found.add((path: path, contents: text.stdout));
      } on CommandException {
        // One unreadable file is not a failed scan.
      }
    }
    return found;
  }
}
