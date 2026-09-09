import 'dart:io';

import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/wda_locator.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('wda_locate_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String plant(String dir) {
    final app = Directory(
      p.join(tmp.path, dir, 'WebDriverAgentRunner-Runner.app'),
    )..createSync(recursive: true);
    return app.path;
  }

  test('prefers the copy inside the app bundle', () {
    final contents = Directory(p.join(tmp.path, 'K.app', 'Contents'))
      ..createSync(recursive: true);
    Directory(p.join(contents.path, 'MacOS')).createSync();
    plant('K.app/Contents/Resources/wda');
    plant('checkout/macos/Vendor/wda');

    final found = WdaLocator(
      hostIsMacOs: true,
      resolvedExecutable: p.join(contents.path, 'MacOS', 'karmashala'),
      workingDirectory: p.join(tmp.path, 'checkout'),
    ).locate();

    expect(found!.source, WdaSource.bundled);
    // Joined rather than spelled with `/`: the locator builds a host path, and
    // on Windows — where this suite also runs — that is `\`. The assertion is
    // about *which* directory was chosen, not about a separator.
    expect(found.appPath, contains(p.join('K.app', 'Contents', 'Resources')));
  });

  test('falls back to the checkout, for anyone running from source', () {
    plant('checkout/macos/Vendor/wda');

    final found = WdaLocator(
      hostIsMacOs: true,
      resolvedExecutable: p.join(tmp.path, 'nowhere', 'app'),
      workingDirectory: p.join(tmp.path, 'checkout'),
    ).locate();

    expect(found!.source, WdaSource.workingTree);
  });

  test('off macOS it finds nothing, without touching the filesystem', () {
    // The bundle is never shipped to Windows or Linux: it lives under macos/,
    // which those builds do not read, and it is deliberately not a Flutter
    // asset, because assets are copied into every platform's bundle.
    plant('checkout/macos/Vendor/wda');

    final found = WdaLocator(
      hostIsMacOs: false,
      resolvedExecutable: p.join(tmp.path, 'nowhere', 'app'),
      workingDirectory: p.join(tmp.path, 'checkout'),
    ).locate();

    expect(found, isNull);
  });

  test('the pinned version travels with the runner', () {
    // The runner is a built binary tied to one version, so "which build is
    // this?" is the first question when it will not attach to a simulator —
    // and the field report could not answer it, because the failure said only
    // that nothing came up.
    final app = plant('K.app/Contents/Resources/wda');
    File(
      p.join(p.dirname(app), '.wda-version'),
    ).writeAsStringSync('v16.12.0 arm64\n');

    final found = WdaLocator(
      hostIsMacOs: true,
      resolvedExecutable: p.join(tmp.path, 'K.app', 'Contents', 'MacOS', 'K'),
      workingDirectory: p.join(tmp.path, 'nowhere'),
    ).locate();

    expect(found?.version, 'v16.12.0 arm64');
  });

  test('and a bundle with no marker is still usable, just unnamed', () {
    // Absent is not an error: a runner assembled by hand works fine.
    plant('K.app/Contents/Resources/wda');

    final found = WdaLocator(
      hostIsMacOs: true,
      resolvedExecutable: p.join(tmp.path, 'K.app', 'Contents', 'MacOS', 'K'),
      workingDirectory: p.join(tmp.path, 'nowhere'),
    ).locate();

    expect(found, isNotNull);
    expect(found!.version, isNull);
  });

  test('no runner anywhere is null, not an exception', () {
    expect(
      WdaLocator(
        hostIsMacOs: true,
        resolvedExecutable: p.join(tmp.path, 'nowhere', 'app'),
        workingDirectory: p.join(tmp.path, 'nowhere'),
      ).locate(),
      isNull,
    );
  });
}
