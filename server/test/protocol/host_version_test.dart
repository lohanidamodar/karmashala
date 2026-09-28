import 'dart:io';

import 'package:karmashala_host_protocol/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The host says which release it is: the app's version, without the build
/// number. Nothing can inject it at build time, so this is what keeps a
/// version bump from leaving the host behind.
void main() {
  test('kHostVersion is the app\'s release', () {
    var dir = Directory.current.absolute;
    while (!File(p.join(dir.path, 'app', 'pubspec.yaml')).existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) fail('no app/pubspec.yaml above the test');
      dir = parent;
    }
    final pubspec = File(p.join(dir.path, 'app', 'pubspec.yaml'));
    final line = pubspec.readAsLinesSync().firstWhere(
      (l) => l.startsWith('version:'),
    );
    final release = line.substring('version:'.length).trim().split('+').first;

    expect(
      kHostVersion,
      release,
      reason: 'bump kHostVersion (host_version.dart) with app/pubspec.yaml',
    );
  });
}
