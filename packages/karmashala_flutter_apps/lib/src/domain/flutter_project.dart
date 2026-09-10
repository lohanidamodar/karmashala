import 'dart:convert';

import 'package:path/path.dart' as p;

/// How deep below a session's root a `pubspec.yaml` may sit and still be one of
/// *this* session's projects; deeper is nearly always a vendored copy.
const int kFlutterProjectMaxDepth = 2;

/// Why a directory reads as a Flutter project. Two signals rather than a
/// boolean: a plugin has only [sdkDependency] and cannot be `flutter run`.
enum FlutterEvidence {
  /// A top-level `flutter:` section — assets, fonts, `uses-material-design`.
  flutterSection,

  /// `flutter: {sdk: flutter}` under `dependencies:` or `dev_dependencies:`.
  sdkDependency,
}

/// What one `pubspec.yaml` says, as far as anything here needs to know.
/// Deliberately not a YAML parse — `package:yaml` is not a dependency here.
class PubspecReading {
  const PubspecReading({
    required this.name,
    required this.evidence,
  });

  /// The package name, or null when the file does not declare one.
  final String? name;

  final Set<FlutterEvidence> evidence;

  /// Whether this pubspec belongs to a Flutter project at all.
  bool get isFlutter => evidence.isNotEmpty;

  /// Whether `flutter run` could be pointed at it: a package that merely
  /// depends on the SDK has no entrypoint, and refusing here costs no work.
  bool get isRunnable => evidence.contains(FlutterEvidence.flutterSection);
}

/// Reads the three facts a Flutter loop needs out of a `pubspec.yaml`.
///
/// Flow mappings, anchors and a `name` inside a block scalar are not
/// understood; a file it misreads reads as "not a Flutter project", the safe
/// direction.
PubspecReading readPubspec(String contents) {
  String? name;
  final evidence = <FlutterEvidence>{};
  // So an indented `flutter:` is attributed to its section, not to the file.
  String? section;
  // Set while a dependency block's own `flutter:` sub-block is being read.
  int? flutterDependencyIndent;

  for (final raw in const LineSplitter().convert(contents)) {
    final line = _withoutComment(raw);
    if (line.trim().isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    final trimmed = line.trim();

    if (indent == 0) {
      section = _keyOf(trimmed);
      flutterDependencyIndent = null;
      if (section == 'name') name = _unquote(_valueOf(trimmed));
      if (section == 'flutter') evidence.add(FlutterEvidence.flutterSection);
      continue;
    }

    if (flutterDependencyIndent != null) {
      // Still inside `dependencies: > flutter:`; `sdk: flutter` is the line
      // that makes it the SDK rather than a package someone named "flutter".
      if (indent > flutterDependencyIndent) {
        if (_keyOf(trimmed) == 'sdk' && _valueOf(trimmed).trim() == 'flutter') {
          evidence.add(FlutterEvidence.sdkDependency);
        }
        continue;
      }
      flutterDependencyIndent = null;
    }

    if (section == 'dependencies' || section == 'dev_dependencies') {
      if (_keyOf(trimmed) == 'flutter') flutterDependencyIndent = indent;
    }
  }

  return PubspecReading(name: name, evidence: evidence);
}

/// One Flutter project found under a session's root.
class FlutterProject {
  const FlutterProject({
    required this.directory,
    required this.pubspecPath,
    required this.name,
    required this.depth,
    required this.evidence,
  });

  /// The directory holding the pubspec — what `flutter` is run in.
  final String directory;

  final String pubspecPath;

  /// The package name, or the directory's own name when the pubspec had none.
  final String name;

  /// Directories below the session root. Zero when the root is the project.
  final int depth;

  final Set<FlutterEvidence> evidence;

  bool get isRunnable => evidence.contains(FlutterEvidence.flutterSection);

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'directory': directory,
    'depth': depth,
    'runnable': isRunnable,
    'evidence': <String>[for (final item in evidence) item.name],
  };
}

/// A `pubspec.yaml` that was found and read, before anything has judged it.
typedef PubspecCandidate = ({String path, String contents});

/// The Flutter projects among [candidates], nearest the root first.
///
/// [context] is the path flavour of the environment the candidates came from,
/// so a backslash path is not measured with a forward-slash ruler.
List<FlutterProject> flutterProjectsIn({
  required String root,
  required Iterable<PubspecCandidate> candidates,
  p.Context? context,
  int maxDepth = kFlutterProjectMaxDepth,
}) {
  final ctx = context ?? p.context;
  final found = <FlutterProject>[];
  for (final candidate in candidates) {
    final reading = readPubspec(candidate.contents);
    if (!reading.isFlutter) continue;
    final directory = ctx.dirname(candidate.path);
    final depth = flutterProjectDepth(root: root, directory: directory, context: ctx);
    if (depth == null || depth > maxDepth) continue;
    found.add(
      FlutterProject(
        directory: directory,
        pubspecPath: candidate.path,
        name: reading.name?.isNotEmpty == true
            ? reading.name!
            : ctx.basename(directory),
        depth: depth,
        evidence: reading.evidence,
      ),
    );
  }
  // Shallowest first, then name, then directory: a caller taking the first
  // gets the root project, and a monorepo's order is stable.
  found.sort((a, b) {
    final byDepth = a.depth.compareTo(b.depth);
    if (byDepth != 0) return byDepth;
    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.directory.compareTo(b.directory);
  });
  return found;
}

/// How many directories [directory] is below [root], or **null when it is not
/// below it at all** — which is not zero (§19).
int? flutterProjectDepth({
  required String root,
  required String directory,
  p.Context? context,
}) {
  final ctx = context ?? p.context;
  final relative = ctx.relative(directory, from: root);
  if (relative == '.') return 0;
  final parts = ctx.split(relative);
  if (parts.any((part) => part == '..')) return null;
  return parts.length;
}

String _withoutComment(String line) {
  final hash = line.indexOf('#');
  if (hash < 0) return line;
  // A `#` inside a quoted value is not a comment.
  final before = line.substring(0, hash);
  final quotes = '"'.allMatches(before).length + "'".allMatches(before).length;
  return quotes.isEven ? before : line;
}

String _keyOf(String trimmed) {
  final colon = trimmed.indexOf(':');
  return colon < 0 ? '' : _unquote(trimmed.substring(0, colon).trim());
}

String _valueOf(String trimmed) {
  final colon = trimmed.indexOf(':');
  return colon < 0 ? '' : trimmed.substring(colon + 1);
}

String _unquote(String value) {
  final trimmed = value.trim();
  if (trimmed.length < 2) return trimmed;
  final first = trimmed[0];
  if ((first == '"' || first == "'") && trimmed.endsWith(first)) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}
