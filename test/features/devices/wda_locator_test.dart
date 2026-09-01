import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/wda_locator.dart';
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
    expect(found.appPath, contains('K.app/Contents/Resources'));
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
