import 'dart:io';

import 'package:karmashala/src/core/logging/build_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// The line every log opens with.
///
/// Its whole job is to be trustworthy: a log that names the wrong version is
/// worse than one that names none, because the reader stops asking. So the
/// only assertions here are that it never invents a version and never omits
/// the facts it genuinely has.
void main() {
  test('names the platform it is actually running on', () {
    final line = buildIdentity();
    expect(line, startsWith('Karmashala '));
    expect(line, contains(Platform.operatingSystem));
    expect(line, contains(Platform.operatingSystemVersion));
  });

  test('says the version is not recorded rather than guessing one', () {
    // The suite runs without `--dart-define=KARMASHALA_VERSION`, so this is
    // the real behaviour of any build that forgets to pass it — which is the
    // case worth pinning. A future change that substitutes a hardcoded
    // constant here would pass a version that drifts, silently.
    expect(appVersion, isEmpty, reason: 'no define under test');
    expect(buildIdentity(), contains('version not recorded'));
    expect(buildIdentity(), isNot(contains('1.2.0')));
  });

  test('defaults to the desktop mode, since only the companion sets one', () {
    expect(appMode, 'desktop');
    expect(buildIdentity(), contains('(desktop)'));
  });
}
