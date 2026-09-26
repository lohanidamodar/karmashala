import 'package:agent_cli/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// A recorded version is a *dated reading*, and this file is about the date.
/// (How a reading is stored is the server's: `karmashala_environments`.)
///
/// The bug: the app reported Claude Code 2.1.252 for a binary answering
/// 2.1.260, and nothing on screen could tell the two apart — a bare number
/// reads exactly like a current one. No refresh rate fixes that; only an age
/// beside the number does.
void main() {
  final read = DateTime.utc(2026, 9, 8, 9);

  group('and says so when it is stale', () {
    test('a fresh reading shows its age', () {
      final row = agentInstallation(version: '2.1.263', versionReadAt: read);

      expect(
        describeVersionReading(row, now: read.add(const Duration(minutes: 4))),
        '2.1.263 · read 4m ago',
      );
    });

    test('a reading past the freshness bound admits it may be wrong', () {
      final row = agentInstallation(version: '2.1.245', versionReadAt: read);

      expect(
        versionFreshness(row, now: read.add(const Duration(days: 3))),
        VersionFreshness.stale,
      );
      expect(
        describeVersionReading(row, now: read.add(const Duration(days: 3))),
        '2.1.245 · last read 3d ago, may be out of date',
      );
    });

    test('an undated number claims neither age nor currency', () {
      final row = agentInstallation(version: '2.1.245');

      expect(versionFreshness(row, now: read), VersionFreshness.undated);
      expect(
        describeVersionReading(row, now: read),
        '2.1.245 · read at an unknown time',
      );
    });

    test('no version at all describes nothing rather than something', () {
      final row = agentInstallation(version: null);

      expect(versionFreshness(row, now: read), VersionFreshness.unknown);
      expect(describeVersionReading(row, now: read), isNull);
    });

    test(
      'the bound the refresh spends a process on is the bound the label uses',
      () {
        // One number in one place. A looser refresh bound would call a version
        // stale and decline to fix it; a tighter one would refresh a version it
        // was still presenting as current.
        final row = agentInstallation(version: '2.1.263', versionReadAt: read);

        expect(
          versionFreshness(row, now: read.add(kVersionReadingFreshFor)),
          VersionFreshness.fresh,
        );
        expect(
          versionFreshness(
            row,
            now: read.add(kVersionReadingFreshFor + const Duration(minutes: 1)),
          ),
          VersionFreshness.stale,
        );
      },
    );
  });
}
