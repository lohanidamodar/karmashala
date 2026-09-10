import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:test/test.dart';

/// The line every log opens with. The assertions are only that it never invents
/// a version and never omits a fact it has: a wrong version is worse than none.
void main() {
  test('names the platform it is actually running on', () {
    final line = buildIdentity();
    expect(line, startsWith('Karmashala '));
    expect(line, contains(Platform.operatingSystem));
    expect(line, contains(Platform.operatingSystemVersion));
  });

  test('says the version is not recorded rather than guessing one', () {
    // The suite runs without `--dart-define=KARMASHALA_VERSION`, so this pins
    // what a build that forgets to pass it actually does.
    expect(appVersion, isEmpty, reason: 'no define under test');
    expect(buildIdentity(), contains('version not recorded'));
    expect(buildIdentity(), isNot(contains('1.2.0')));
  });

  test('defaults to the desktop mode, since only the companion sets one', () {
    expect(appMode, 'desktop');
    expect(buildIdentity(), contains('(desktop)'));
  });
}
