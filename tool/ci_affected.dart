// Which suites a change can break: each changed file's owner (app, server, a
// package, the relay) plus everything that depends on it through a path
// dependency, transitively. CI tests only those on a pull request.
//
//   git diff --name-only <base>...HEAD | dart tool/ci_affected.dart
//   dart tool/ci_affected.dart --all
//
// Prints `app=`, `relay=`, `members=` (a JSON list of the server and package
// directories to test) and `member_shards=` (those, split for parallel
// runners), in the form `$GITHUB_OUTPUT` takes.
//
// Plain `dart:io` and run without `dart run`, so it needs no `pub get`.
import 'dart:convert';
import 'dart:io';

/// A change here can move every suite: the resolution, the lints, CI itself.
const _everything = {
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
  '.github/workflows/ci.yml',
  'tool/ci_affected.dart',
};

void main(List<String> args) {
  final members = _members();
  final dependents = <String, Set<String>>{};
  for (final member in members) {
    for (final dependency in _pathDependencies(member)) {
      dependents.putIfAbsent(dependency, () => {}).add(member);
    }
  }

  final affected = args.contains('--all')
      ? members.toSet()
      : _affected(_changedFiles(), members, dependents);

  final tested = [
    for (final member in affected)
      if (member != 'app' &&
          !member.startsWith('relay') &&
          Directory('$member/test').existsSync())
        member,
  ]..sort();
  // Every third member per shard, so each gets a mix of large and small
  // suites; no empty shard, so no runner starts for nothing.
  const shardCount = 3;
  final shards = [
    for (var i = 0; i < shardCount && i < tested.length; i++)
      [for (var j = i; j < tested.length; j += shardCount) tested[j]].join(' '),
  ];
  stdout
    ..writeln('app=${affected.contains('app')}')
    ..writeln('relay=${affected.any((m) => m.startsWith('relay'))}')
    ..writeln('members=${jsonEncode(tested)}')
    ..writeln('member_shards=${jsonEncode(shards)}');
}

List<String> _changedFiles() {
  final files = <String>[];
  String? line;
  while ((line = stdin.readLineSync()) != null) {
    final file = line!.trim().replaceAll(r'\', '/');
    if (file.isNotEmpty) files.add(file);
  }
  return files;
}

Set<String> _affected(
  List<String> changed,
  List<String> members,
  Map<String, Set<String>> dependents,
) {
  if (changed.any(_everything.contains)) return members.toSet();
  // Longest first, so relay/protocol/x belongs to relay/protocol, not relay.
  final byLength = [...members]..sort((a, b) => b.length - a.length);
  final affected = <String>{};
  final pending = <String>[];
  for (final file in changed) {
    for (final member in byLength) {
      if (file.startsWith('$member/')) {
        pending.add(member);
        break;
      }
    }
  }
  while (pending.isNotEmpty) {
    final member = pending.removeLast();
    if (affected.add(member)) pending.addAll(dependents[member] ?? const {});
  }
  return affected;
}

/// Every directory with a pubspec that CI knows how to test.
List<String> _members() => [
  'app',
  'server',
  'relay',
  'relay/protocol',
  for (final dir in Directory('packages').listSync().whereType<Directory>())
    if (File('${dir.path}/pubspec.yaml').existsSync())
      'packages/${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}',
];

/// The members [member] reaches through `path:` dependencies of any kind
/// (dependencies, dev_dependencies, overrides).
Iterable<String> _pathDependencies(String member) sync* {
  final pubspec = File('$member/pubspec.yaml');
  if (!pubspec.existsSync()) return;
  final path = RegExp(r'^\s+path:\s*["\x27]?([^"\x27\s#]+)');
  for (final line in pubspec.readAsLinesSync()) {
    final match = path.firstMatch(line);
    if (match == null) continue;
    yield _normalize('$member/${match.group(1)}');
  }
}

String _normalize(String path) {
  final out = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(segment);
    }
  }
  return out.join('/');
}
