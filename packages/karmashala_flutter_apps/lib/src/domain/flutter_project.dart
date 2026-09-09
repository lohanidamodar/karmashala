import 'dart:convert';

import 'package:path/path.dart' as p;

/// How deep below a session's root a `pubspec.yaml` may sit and still be one
/// of *this* session's projects.
///
/// Two, from the backlog item. `app/pubspec.yaml` and
/// `packages/mobile/pubspec.yaml` are both this checkout's work; a pubspec
/// three levels down is nearly always a vendored copy or a package's own
/// example, and offering to run it is offering the wrong project.
const int kFlutterProjectMaxDepth = 2;

/// Why a directory reads as a Flutter project.
///
/// Two independent signals, kept apart rather than collapsed into a boolean,
/// because they answer different questions. A **runnable app** has both; a
/// **plugin or package** usually has only [sdkDependency] and cannot be
/// `flutter run`, which is exactly the difference a launch has to refuse on.
enum FlutterEvidence {
  /// A top-level `flutter:` section — assets, fonts, `uses-material-design`.
  flutterSection,

  /// `flutter: {sdk: flutter}` under `dependencies:` or `dev_dependencies:`.
  sdkDependency,
}

/// What one `pubspec.yaml` says, as far as anything here needs to know.
///
/// **Deliberately not a YAML parse.** The three facts wanted are all top-level
/// or one level in, `package:yaml` is not a dependency of this app, and adding
/// a parser for `name:` would be the "dependency for trivial helper logic"
/// CLAUDE.md §3 forbids. What this costs is spelled out in [readPubspec].
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

  /// Whether `flutter run` could be pointed at it.
  ///
  /// A package that merely depends on the Flutter SDK has no entrypoint and no
  /// device to run on; `flutter run` in one answers *"this is not a Flutter
  /// project"* after doing work. Knowing it here means the refusal is a
  /// sentence instead.
  bool get isRunnable => evidence.contains(FlutterEvidence.flutterSection);
}

/// Reads the three facts a Flutter loop needs out of a `pubspec.yaml`.
///
/// **What this scan does and does not see.** It reads unindented `name:` and
/// `flutter:` keys, and the one-level-in `flutter:` under `dependencies:` or
/// `dev_dependencies:` whose block names the SDK. It ignores comments and
/// blank lines. It does **not** understand flow mappings (`dependencies: {…}`),
/// anchors, or a `name` inside a block scalar — all three are legal YAML and
/// none of them occur in a pubspec `flutter create` or a human writes. A file
/// it misreads reads as "not a Flutter project", which is the safe direction:
/// the app then offers nothing rather than offering to run the wrong thing.
PubspecReading readPubspec(String contents) {
  String? name;
  final evidence = <FlutterEvidence>{};
  // Which top-level block the cursor is in, so an indented `flutter:` is
  // attributed to the section that contains it rather than to the file.
  String? section;
  // The indent of a `flutter:` key inside a dependency block, while its own
  // sub-block is still being read.
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
/// **Pure, and that is the point.** Deciding what a checkout holds is a
/// question about text; finding the text is a question about a filesystem that
/// may be a distribution or another machine. Splitting them is what lets the
/// decision be pinned by a test with no disk in it, and what keeps the walk on
/// the side of the line where it happens *when someone asks* rather than on a
/// tick.
///
/// [context] is the path flavour of the environment the candidates came from —
/// `p.windows` for a Windows checkout, `p.posix` for a distribution — so a
/// backslash path is not measured with a forward-slash ruler.
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
  // Shallowest first, then by name, then by directory — so the root project
  // of a checkout is what a caller taking the first gets, and a monorepo whose
  // packages share a name still comes back in one order every time.
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
  // A `#` inside a quoted value is not a comment. Nothing this reads has one,
  // and cutting the line there would only lose a value it does not use — but
  // the cheap guard costs one condition.
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
