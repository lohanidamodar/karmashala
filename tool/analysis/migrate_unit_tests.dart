// One-shot migration: moves Flutter-free test files to test/unit/, swaps
// package:flutter_test for package:test, tags them `unit`, and repairs every
// relative import that the move invalidates (in the moved file and in whatever
// still points at it).
//
// Usage: dart tool/analysis/migrate_unit_tests.dart <list-file>
import 'dart:io';

String norm(String p) => p.replaceAll('\\', '/');

String newPathFor(String old) => 'test/unit/${old.substring('test/'.length)}';

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

/// Adds the `unit` tag, merging with an existing @Tags annotation.
String addUnitTag(String src) {
  final existing = RegExp(r'^@Tags\(\[([^\]]*)\]\)', multiLine: true).firstMatch(src);
  if (existing != null) {
    final inner = existing.group(1)!.trim();
    return src.replaceRange(
      existing.start,
      existing.end,
      "@Tags([${inner.isEmpty ? '' : '$inner, '}'unit'])",
    );
  }
  final testOn = RegExp(r'^@TestOn\([^)]*\)\s*$', multiLine: true).firstMatch(src);
  if (testOn != null) {
    return src.replaceRange(testOn.end, testOn.end, "\n@Tags(['unit'])");
  }
  if (RegExp(r'^library\b', multiLine: true).hasMatch(src)) {
    return "@Tags(['unit'])\n$src";
  }
  return "@Tags(['unit'])\nlibrary;\n\n$src";
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: migrate_unit_tests.dart <list-file>');
    exit(2);
  }
  final list = File(args.first)
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  final moved = {for (final f in list) f: newPathFor(f)};

  for (final old in list) {
    final target = moved[old]!;
    Directory(File(target).parent.path).createSync(recursive: true);
    File(old).renameSync(target);
    var src = File(target).readAsStringSync();
    src = rewriteRelatives(src, old, target, moved);
    src = src.replaceAll(
      'package:flutter_test/flutter_test.dart',
      'package:test/test.dart',
    );
    src = addUnitTag(src);
    File(target).writeAsStringSync(src);
  }

  // Anything left behind that pointed at a moved file needs the new path.
  var repaired = 0;
  for (final entity in Directory('test').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = norm(entity.path);
    if (path.startsWith('test/unit/')) continue;
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
