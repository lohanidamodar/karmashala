/// Every build script and release workflow gives the app the same hosted
/// relay, and it is the one [kPopupBitsRelayUrl] names: a build that drifted
/// would pair its phones somewhere the rest no longer meet them.
library;

import 'dart:io';

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// Where official builds take `KARMASHALA_RELAY_URL` from.
const _sources = [
  'tool/build_release.bat',
  'tool/build_release.sh',
  'tool/debug_run.bat',
  'tool/profile_run.bat',
  'tool/app_soak.ps1',
  '.github/workflows/release-build.yml',
  '.github/workflows/android-release.yml',
  'app/dart_defines.json',
];

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/tool/build_release.bat').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('repository root not found');
    dir = parent;
  }
  return dir;
}

/// Every relay URL [text] gives the define, in either spelling.
List<String> _definedRelays(String text) => [
  for (final match in RegExp(
    r'''KARMASHALA_RELAY_URL"?\s*[=:]\s*"?(wss?://[^\s"')]+)''',
  ).allMatches(text))
    match.group(1)!,
];

void main() {
  final root = _repoRoot();

  for (final source in _sources) {
    test('$source names the PopupBits relay', () {
      final relays = _definedRelays(
        File('${root.path}/$source').readAsStringSync(),
      );
      expect(relays, isNotEmpty, reason: '$source defines no relay');
      expect(relays.toSet(), {kPopupBitsRelayUrl});
    });
  }

  test('the PopupBits relay is not also listed as retired', () {
    expect(kRetiredPopupBitsRelayUrls, isNot(contains(kPopupBitsRelayUrl)));
  });
}
