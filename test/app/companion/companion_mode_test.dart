import 'package:chitragupta/src/app/companion/companion_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// The build-time mode switch. The rule itself is pinned here; that `enabled`
/// applies the rule to the define is one line read alongside it — and this
/// suite runs with no define, which is exactly the desktop default the
/// existing 2,555 tests depend on.
void main() {
  test('only the exact word selects companion mode', () {
    expect(CompanionMode.isCompanion('companion'), isTrue);
    expect(CompanionMode.isCompanion(''), isFalse);
    expect(CompanionMode.isCompanion('Companion'), isFalse);
    expect(CompanionMode.isCompanion('desktop'), isFalse);
    expect(CompanionMode.isCompanion('companion '), isFalse);
  });

  test('an undefined CHITRAGUPTA_MODE is the desktop', () {
    // This suite is compiled without the define, so this asserts the desktop
    // path is the default — the branch the whole existing suite exercises.
    expect(CompanionMode.enabled, isFalse);
  });
}
