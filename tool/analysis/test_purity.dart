// Reports which test files could run on plain `dart test` — i.e. whose
// transitive imports never reach `package:flutter` or `dart:ui`. See
// docs/BACKLOG.md, "What the test gate actually costs", for why that question
// turned out not to be the interesting one.
//
//   --seams   rank the first Flutter-reaching hop out of each blocked test
//   --rank    price each seam by how many tests it alone would release
//   --json    machine-readable widget / pure / blocked lists
//   --ignore=<substring>  pretend matching imports are absent (what-if runs)
import 'dart:convert';
import 'dart:io';

final _importRe = RegExp(
  '''^\\s*(?:import|export)\\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

final Map<String, String> packageRoots = _readPackageConfig();

Map<String, String> _readPackageConfig() {
  final file = File('.dart_tool/package_config.json');
  if (!file.existsSync()) {
    stderr.writeln('missing .dart_tool/package_config.json — run pub get');
    exit(2);
  }
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final roots = <String, String>{};
  for (final entry in (json['packages'] as List).cast<Map<String, dynamic>>()) {
    final name = entry['name'] as String;
    var root = entry['rootUri'] as String;
    final pkgRoot = (entry['packageUri'] as String?) ?? 'lib/';
    Uri base;
    if (root.startsWith('../')) {
      base = Directory('.dart_tool').uri.resolve('$root/');
    } else {
      base = Uri.parse(root.endsWith('/') ? root : '$root/');
    }
    roots[name] = base.resolve(pkgRoot).toFilePath();
  }
  return roots;
}

/// Resolves an import URI seen in [fromFile] to an absolute file path, or null
/// for dart: SDK libraries and anything unresolvable.
String? resolve(String uri, String fromFile) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return null;
    final pkg = rest.substring(0, slash);
    final root = packageRoots[pkg];
    if (root == null) return null;
    return _norm('$root${rest.substring(slash + 1)}');
  }
  final parts = _norm(File(fromFile).parent.path).split('/');
  for (final seg in uri.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

String _norm(String p) => p.replaceAll('\\', '/');

final _importCache = <String, List<String>>{};

List<String> importsOf(String path) => _importCache.putIfAbsent(path, () {
  final file = File(path);
  if (!file.existsSync()) return const [];
  final src = file.readAsStringSync();
  return _importRe.allMatches(src).map((m) => m.group(1)!).toList();
});

/// Imports to pretend are absent, for "what would this seam unblock?" runs.
final Set<String> ignored = {};

/// Files to treat as Flutter-free, for the same reason.
final Set<String> pretendPure = {};

/// True when [uri] is Flutter itself (as opposed to something that merely
/// imports it — that is what the traversal is for).
bool isFlutterUri(String uri) =>
    uri.startsWith('package:flutter/') ||
    uri == 'dart:ui' ||
    uri.startsWith('dart:ui');

final _reachCache = <String, bool>{};

/// Whether [path] reaches Flutter through its own imports.
///
/// [dropFlutterTest] is only ever true for the test file being classified: the
/// migration rewrites *its* flutter_test import, but a shared helper's stays,
/// so a helper that imports flutter_test really does block.
bool reachesFlutter(String path, Set<String> stack, {bool dropFlutterTest = false}) {
  final cached = _reachCache[path];
  if (cached != null) return cached;
  if (!stack.add(path)) return false; // cycle: no new information
  var result = false;
  for (final uri in importsOf(path)) {
    if (ignored.any(uri.contains)) continue;
    if (isFlutterUri(uri)) {
      result = true;
      break;
    }
    if (dropFlutterTest && uri.startsWith('package:flutter_test/')) continue;
    final target = resolve(uri, path);
    if (target == null || pretendPure.contains(target)) continue;
    if (reachesFlutter(target, stack)) {
      result = true;
      break;
    }
  }
  stack.remove(path);
  _reachCache[path] = result;
  return result;
}

/// The first hop out of [path] that reaches Flutter, for blame reporting.
String? blameSeam(String path) {
  for (final uri in importsOf(path)) {
    if (isFlutterUri(uri)) return uri;
    if (uri.startsWith('package:flutter_test/')) continue;
    final target = resolve(uri, path);
    if (target == null) continue;
    if (reachesFlutter(target, <String>{})) return target;
  }
  return null;
}

void main(List<String> args) {
  for (final a in args.where((a) => a.startsWith('--ignore='))) {
    ignored.add(a.substring('--ignore='.length));
  }
  final root = Directory('test');
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('_test.dart'))
      .map((f) => _norm(f.path))
      .toList()
    ..sort();

  if (args.contains('--rank')) {
    _rank(files);
    return;
  }

  final widget = <String>[];
  final pure = <String>[];
  final blocked = <String, String>{};

  for (final f in files) {
    final src = File(f).readAsStringSync();
    if (src.contains('testWidgets(') ||
        src.contains('WidgetTester') ||
        src.contains('pumpWidget')) {
      widget.add(f);
      continue;
    }
    _reachCache.remove(f);
    if (reachesFlutter(f, <String>{}, dropFlutterTest: true)) {
      blocked[f] = blameSeam(f) ?? '?';
    } else {
      pure.add(f);
    }
  }

  if (args.contains('--json')) {
    stdout.writeln(jsonEncode({
      'widget': widget,
      'pure': pure,
      'blocked': blocked,
    }));
    return;
  }

  stdout.writeln('total test files   ${files.length}');
  stdout.writeln('  widget (stay)    ${widget.length}');
  stdout.writeln('  pure (movable)   ${pure.length}');
  stdout.writeln('  blocked          ${blocked.length}');

  if (args.contains('--seams')) {
    final tally = <String, int>{};
    for (final seam in blocked.values) {
      tally[seam] = (tally[seam] ?? 0) + 1;
    }
    final ranked = tally.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    stdout.writeln('\nseams blocking the most tests:');
    for (final e in ranked.take(40)) {
      stdout.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
    }
  }
}

/// Counts how many currently-blocked tests each seam would release on its own.
void _rank(List<String> files) {
  final nonWidget = files.where((f) {
    final src = File(f).readAsStringSync();
    return !src.contains('testWidgets(') &&
        !src.contains('WidgetTester') &&
        !src.contains('pumpWidget');
  }).toList();

  int pureCount() {
    _reachCache.clear();
    var n = 0;
    for (final f in nonWidget) {
      _reachCache.remove(f);
      if (!reachesFlutter(f, <String>{}, dropFlutterTest: true)) n++;
    }
    return n;
  }

  final base = pureCount();
  final candidates = <String>{};
  _reachCache.clear();
  for (final f in nonWidget) {
    _reachCache.remove(f);
    if (reachesFlutter(f, <String>{}, dropFlutterTest: true)) {
      final s = blameSeam(f);
      if (s != null) candidates.add(s);
    }
  }
  // Every file on a blame chain is worth pricing, not just the first hop.
  final deltas = <String, int>{};
  for (final c in candidates) {
    pretendPure.add(c);
    deltas[c] = pureCount() - base;
    pretendPure.remove(c);
  }
  final ranked = deltas.entries.where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('baseline pure (non-widget): $base of ${nonWidget.length}');
  stdout.writeln('tests each seam would release on its own:');
  for (final e in ranked) {
    stdout.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }
}
