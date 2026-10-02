// Splits a package's test files across CI runners by directory, so each runner
// compiles only its own share. `flutter test --total-shards` cannot do this: it
// splits the tests inside every file, so every runner still compiles them all,
// and a file whose tests lean on each other runs half of itself.
//
//   dart tool/ci_test_shards.dart app 2 4    # shard 2 of 4, 1-based
//
// Prints the paths for that shard, relative to the package, one per line:
// whole directories where possible, because `flutter` on Windows is a batch
// file and cmd caps a command line at 8191 characters.
//
// Plain `dart:io` and run without `dart run`, so it needs no `pub get`.
import 'dart:io';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln('usage: ci_test_shards.dart <package> <shard> <total>');
    exit(64);
  }
  final package = args[0];
  final shard = int.parse(args[1]);
  final total = int.parse(args[2]);

  // A unit is what one runner takes whole: each folder under test/features,
  // each other folder under test, and each test file directly in test/.
  final test = Directory('$package/test');
  final units = <String, int>{};
  for (final entity in test.listSync()) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (entity is File && name.endsWith('_test.dart')) {
      units['test/$name'] = 1;
    } else if (entity is Directory && name == 'features') {
      for (final feature in entity.listSync().whereType<Directory>()) {
        final f = feature.uri.pathSegments.where((s) => s.isNotEmpty).last;
        units['test/features/$f'] = _count(feature);
      }
    } else if (entity is Directory) {
      units['test/$name'] = _count(entity);
    }
  }
  units.removeWhere((_, files) => files == 0);

  // Largest first onto the lightest runner; names break ties, so every runner
  // computes the same split.
  final ordered = units.keys.toList()
    ..sort((a, b) {
      final bySize = units[b]!.compareTo(units[a]!);
      return bySize != 0 ? bySize : a.compareTo(b);
    });
  final loads = List.filled(total, 0);
  final bins = List.generate(total, (_) => <String>[]);
  for (final unit in ordered) {
    var lightest = 0;
    for (var i = 1; i < total; i++) {
      if (loads[i] < loads[lightest]) lightest = i;
    }
    loads[lightest] += units[unit]!;
    bins[lightest].add(unit);
  }
  stderr.writeln('test files per shard: ${loads.join(', ')}');
  for (final unit in bins[shard - 1]..sort()) {
    stdout.writeln(unit);
  }
}

int _count(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('_test.dart'))
    .length;
