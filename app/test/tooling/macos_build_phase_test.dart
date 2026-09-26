@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `${SRCROOT}`-relative script a Runner build phase invokes has to be in
/// the repository, or the macOS build fails on a fresh clone.
///
/// This existed as a real break: `.gitignore` ignored `macos/Vendor/` wholesale
/// to keep the 18 MB vendored WebDriverAgent blob out of the repo, and that also
/// swallowed `copy_wda.sh` — which the "Run Script" phase runs unconditionally.
/// The script is careful to tolerate a *missing blob* (it warns and exits 0), so
/// the checkout that has never run `tool/vendor/fetch_wda.sh` was meant to build
/// fine. It could not: the phase died with `No such file or directory` before
/// the script's own tolerance could apply. Only worktrees that happened to have
/// fetched the blob built at all.
///
/// Asserted by parsing the project file rather than by naming `copy_wda.sh`, so
/// a build phase added later is covered without anyone remembering to come here.
void main() {
  test('scripts run by a Runner build phase are tracked by git', () {
    final project = File('macos/Runner.xcodeproj/project.pbxproj');
    expect(
      project.existsSync(),
      isTrue,
      reason: 'run this from the package root',
    );

    // `shellScript = "...";` holds the phase body with its quotes escaped.
    final bodies = RegExp(
      r'shellScript = "((?:[^"\\]|\\.)*)";',
    ).allMatches(project.readAsStringSync()).map((m) => m.group(1)!);

    final referenced = <String>{};
    for (final body in bodies) {
      for (final m in RegExp(
        r'\$\{SRCROOT\}/([A-Za-z0-9_./-]+)',
      ).allMatches(body)) {
        referenced.add('macos/${m.group(1)}');
      }
    }
    expect(
      referenced,
      isNotEmpty,
      reason: 'no ${'\$'}{SRCROOT} script references found — regex stale?',
    );

    for (final path in referenced) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'build phase runs $path, which is not in the working tree',
      );
      // Present locally is not enough: an ignored file is absent for everyone
      // else, which is exactly how this broke.
      final tracked = Process.runSync('git', [
        'ls-files',
        '--error-unmatch',
        path,
      ]);
      expect(
        tracked.exitCode,
        0,
        reason:
            'build phase runs $path, but git does not track it — a fresh clone '
            'will fail with "No such file or directory". Narrow the .gitignore '
            'rule rather than ignoring the whole directory.',
      );
    }
  });
}
