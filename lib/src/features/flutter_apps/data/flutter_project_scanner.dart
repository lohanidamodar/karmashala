import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/flutter_project.dart';

/// Directory names never worth descending into looking for a project.
///
/// `build/` and `.dart_tool/` hold *copies* of pubspecs — a plugin's staged
/// package cache is full of them — and offering to run one would point the
/// loop at a generated tree. Everything beginning with a dot is skipped for
/// the same reason plus one more: `.karmashala-worktrees` is a sibling
/// checkout, whose projects belong to it and not to this session.
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
/// environment.
///
/// **Two ways in, because there are two kinds of filesystem.** The local host
/// — Windows or POSIX — is read with `dart:io`, which is the same disk this
/// process is on and costs no subprocess at all. A distribution or another
/// machine is read through the [CommandRunner] the environment already has,
/// because there is no other way to see it. Both hand the same text to the
/// same pure decision in `flutterProjectsIn`.
///
/// **It runs when someone asks.** Nothing here is on a timer or a rebuild: a
/// walk of a checkout costs stats, and a walk of an SSH checkout costs a round
/// trip, so the answer carries the time it was taken and is re-taken on
/// demand (§19).
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
            found.add((path: pubspec.path, contents: pubspec.readAsStringSync()));
          } on FileSystemException {
            // A pubspec we cannot read is not a project we can offer to run,
            // and it is not an error worth failing the whole scan for.
          }
        }
        if (depth == maxDepth) continue;
        try {
          for (final entry in Directory(directory).listSync(followLinks: false)) {
            if (entry is! Directory) continue;
            final name = _context.basename(entry.path);
            if (name.startsWith('.') || kFlutterScanSkips.contains(name)) continue;
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
            '-maxdepth', '${maxDepth + 1}',
            '-name', 'pubspec.yaml',
            '-not', '-path', '*/.*',
            for (final skip in kFlutterScanSkips) ...<String>[
              '-not', '-path', '*/$skip/*',
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
        // Same rule as the local branch: one unreadable file is not a failed
        // scan.
      }
    }
    return found;
  }
}
