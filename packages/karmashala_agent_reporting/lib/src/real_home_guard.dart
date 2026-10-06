import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A test pointed an agent-store writer at the real user home.
class RealHomeUnderTestError extends Error {
  RealHomeUnderTestError(this.path);

  final String path;

  @override
  String toString() =>
      'RealHomeUnderTestError: a test reached the real agent store $path; '
      'give the code under test a temp home or a stub store locator';
}

/// Refuses [path] while a test runner is running when it lies in the real
/// user home outside the system temp folder. Throws, and also reports to the
/// current zone, so a caller that swallows the throw still fails the test.
void refuseRealHomeUnderTest(
  String path, {
  Map<String, String>? environment,
  String? temp,
  bool? underTest,
  void Function(Object error, StackTrace stack)? report,
}) {
  if (!(underTest ?? _underTestRunner)) return;
  final env = environment ?? Platform.environment;
  final target = p.canonicalize(path);
  final tempRoot = p.canonicalize(temp ?? Directory.systemTemp.path);
  if (_inside(target, tempRoot)) return;
  for (final key in const ['USERPROFILE', 'HOME']) {
    final home = env[key];
    if (home == null || home.isEmpty) continue;
    if (!_inside(target, p.canonicalize(home))) continue;
    final error = RealHomeUnderTestError(path);
    final stack = StackTrace.current;
    (report ?? Zone.current.handleUncaughtError)(error, stack);
    Error.throwWithStackTrace(error, stack);
  }
}

bool _inside(String path, String root) =>
    p.equals(path, root) || p.isWithin(root, path);

/// `flutter test` sets `FLUTTER_TEST`; `dart test` runs each suite from a
/// kernel file in a `dart_test.kernel.*` folder.
final bool _underTestRunner =
    Platform.environment['FLUTTER_TEST'] == 'true' ||
    Platform.script.path.contains('dart_test.kernel');
