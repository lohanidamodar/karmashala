// Moves Flutter-free test files out of `test/`, swaps package:flutter_test for
// package:test, optionally tags them, and repairs every relative import that
// the move invalidates (in the moved file and in whatever still points at it).
//
// Written for the one-shot `test/unit/` migration; the package split reuses it
// to lift a package's suites into `packages/<p>/test/`, which is what the
// options are for.
//
// Usage: dart tool/analysis/migrate_unit_tests.dart <list-file> [options]
//   --dest <root>      where the files land        (default `test/unit`)
//   --strip <prefix>   path prefix dropped first   (default `test/`)
//   --tag <name>       tag added to each suite (default `unit`)
//   --no-tag           add none
//   --at <old>=<new>   a helper that is *not* moved but also exists at <new>
//                      (copied into the destination tree): relative imports of
//                      <old> in the moved files are repointed at <new>, and the
//                      sweep below leaves referrers of <old> alone
//   --no-repair        skip that sweep over what stayed behind
import 'dart:io';

String norm(String p) => p.replaceAll('\\', '/');

String _dest = 'test/unit';
String _strip = 'test/';

String newPathFor(String old) => '$_dest/${old.substring(_strip.length)}';

/// Relative path from the directory of [fromFile] to [target].
String relativeFrom(String fromFile, String target) {
  final from = norm(File(fromFile).parent.path).split('/');
  final to = norm(target).split('/');
  var i = 0;
  while (i < from.length && i < to.length && from[i] == to[i]) {
    i++;
  }
  final ups = List.filled(from.length - i, '..');
  final rest = to.sublist(i);
  final joined = [...ups, ...rest].join('/');
  return joined.startsWith('.') ? joined : './$joined';
}

String resolveRelative(String fromFile, String uri) {
  final dir = norm(File(fromFile).parent.path);
  final parts = <String>[...dir.split('/')];
  for (final seg in uri.split('/')) {
    if (seg == '.' || seg.isEmpty) continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

final _directiveRe = RegExp(
  '''^(\\s*(?:import|export)\\s+)(['"])([^'"]+)(['"])''',
  multiLine: true,
);

/// Rewrites every relative directive in [src] as seen from [newFile], given the
/// file used to live at [oldFile]. [moved] maps old paths to new ones.
String rewriteRelatives(
  String src,
  String oldFile,
  String newFile,
  Map<String, String> moved,
) {
  return src.replaceAllMapped(_directiveRe, (m) {
    final uri = m.group(3)!;
    if (uri.startsWith('package:') || uri.startsWith('dart:')) return m.group(0)!;
    var target = resolveRelative(oldFile, uri);
    target = moved[target] ?? target;
    return '${m.group(1)}${m.group(2)}${relativeFrom(newFile, target)}${m.group(4)}';
  });
}

/// Adds [tag], merging with an existing @Tags annotation.
String addTag(String src, String tag) {
  if (tag.isEmpty) return src;
  final existing = RegExp(r'^@Tags\(\[([^\]]*)\]\)', multiLine: true).firstMatch(src);
  if (existing != null) {
    final inner = existing.group(1)!.trim();
    return src.replaceRange(
      existing.start,
      existing.end,
      "@Tags([${inner.isEmpty ? '' : '$inner, '}'$tag'])",
    );
  }
  final testOn = RegExp(r'^@TestOn\([^)]*\)\s*$', multiLine: true).firstMatch(src);
  if (testOn != null) {
    return src.replaceRange(testOn.end, testOn.end, "\n@Tags(['$tag'])");
  }
  if (RegExp(r'^library\b', multiLine: true).hasMatch(src)) {
    return "@Tags(['$tag'])\n$src";
  }
  return "@Tags(['$tag'])\nlibrary;\n\n$src";
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: migrate_unit_tests.dart <list-file> '
      '[--dest <root>] [--strip <prefix>] [--tag <name>|--no-tag] '
      '[--at <old>=<new>] [--no-repair]',
    );
    exit(2);
  }
  var tag = 'unit';
  var repair = true;
  final aliases = <String, String>{};
  for (var i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--dest':
        _dest = norm(args[++i]);
      case '--strip':
        _strip = norm(args[++i]);
      case '--tag':
        tag = args[++i];
      case '--no-tag':
        tag = '';
      case '--at':
        final pair = args[++i].split('=');
        aliases[norm(pair[0])] = norm(pair[1]);
      case '--no-repair':
        repair = false;
      default:
        stderr.writeln('unknown option: ${args[i]}');
        exit(2);
    }
  }
  final list = File(args.first)
      .readAsLinesSync()
      .map((l) => norm(l.trim()))
      .where((l) => l.isNotEmpty)
      .toList();

  final moved = {for (final f in list) f: newPathFor(f)};
  // Aliases repoint imports without renaming anything, so they belong to the
  // moved files' rewrite but not to the sweep over what stayed behind.
  final withAliases = {...moved, ...aliases};

  for (final old in list) {
    final target = moved[old]!;
    Directory(File(target).parent.path).createSync(recursive: true);
    File(old).renameSync(target);
    var src = File(target).readAsStringSync();
    src = rewriteRelatives(src, old, target, withAliases);
    src = src.replaceAll(
      'package:flutter_test/flutter_test.dart',
      'package:test/test.dart',
    );
    src = addTag(src, tag);
    File(target).writeAsStringSync(src);
  }

  // Anything left behind that pointed at a moved file needs the new path.
  var repaired = 0;
  for (final entity in repair
      ? Directory('test').listSync(recursive: true)
      : const <FileSystemEntity>[]) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = norm(entity.path);
    if (path.startsWith('$_dest/')) continue;
    final src = entity.readAsStringSync();
    final out = src.replaceAllMapped(_directiveRe, (m) {
      final uri = m.group(3)!;
      if (uri.startsWith('package:') || uri.startsWith('dart:')) return m.group(0)!;
      final target = resolveRelative(path, uri);
      final now = moved[target];
      if (now == null) return m.group(0)!;
      return '${m.group(1)}${m.group(2)}${relativeFrom(path, now)}${m.group(4)}';
    });
    if (out != src) {
      entity.writeAsStringSync(out);
      repaired++;
    }
  }

  stdout.writeln('moved ${list.length} files; repaired $repaired referrers');
}
