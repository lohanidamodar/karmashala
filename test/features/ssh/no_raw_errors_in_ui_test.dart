import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **A source guard.** On 2026-09-17 setting up a relay showed
/// "Bad state: The Karmashala host could not be put on …": a `StateError`
/// thrown where a reason was known, then drawn with `'$error'`. Both halves are
/// closed here by reading the source, because no widget test can enumerate the
/// errors somebody will interpolate next.
void main() {
  /// Everything that words what a person reads about an SSH host or a relay.
  final surfaces = [
    Directory('lib/src/features/ssh/presentation'),
    Directory('lib/src/features/ssh/application'),
    Directory('lib/src/features/remote/presentation'),
  ];
  final files = [
    for (final directory in surfaces)
      ...directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
    File('lib/src/features/remote/application/ssh_relay_controller.dart'),
  ];

  /// A caught error dropped into a string as it is: `'$error'`, `'… ($e)'`,
  /// `'${error}'`. Its `toString` leads with the class's own words.
  final rawError = RegExp(r'\$\{?(e|error|err|exception|failure)\}?(?![\w.(])');

  test('the guard is looking at real files', () {
    expect(files.length, greaterThan(20));
  });

  test('no caught error is interpolated into text as it is', () {
    final found = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        // A log line is not UI, and says what it caught on purpose.
        if (line.contains('_logger.') || line.contains('logger?.')) continue;
        if (rawError.hasMatch(line)) found.add('${file.path}:${i + 1}  $line');
      }
    }
    expect(
      found,
      isEmpty,
      reason:
          'word it with describeSshFailure, or carry a typed failure '
          '(HostDeployFailure) to a HostDeployFailureNotice',
    );
  });

  test('nothing here throws a StateError for a person to read', () {
    final found = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('throw StateError(')) {
          found.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(found, isEmpty, reason: 'its toString is "Bad state: …"');
  });

  test('and "Bad state" is written nowhere as a sentence', () {
    for (final file in files) {
      final text = file.readAsStringSync();
      // The one mention allowed is the comment that explains the stripping.
      final mentions = 'Bad state'.allMatches(text).length;
      final inComments = RegExp(r'//.*Bad state').allMatches(text).length;
      expect(mentions, inComments, reason: file.path);
    }
  });
}
