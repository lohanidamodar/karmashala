import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/idb_companion_locator.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('idb_locate_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A companion tree: the executable plus the sibling Resources it resolves
  /// its guest binaries from.
  String plant(String dir, {bool withResources = true}) {
    final home = Directory(p.join(tmp.path, dir))..createSync(recursive: true);
    final exe = File(p.join(home.path, 'idb_companion'))..writeAsStringSync('');
    if (withResources) {
      Directory(p.join(home.path, 'Resources')).createSync();
    }
    return exe.path;
  }

  test('prefers the copy inside the app bundle', () {
    // Contents/MacOS/<app> is where a running .app puts us; the pinned build
    // sits in Contents/Resources.
    final contents = Directory(p.join(tmp.path, 'K.app', 'Contents'))
      ..createSync(recursive: true);
    Directory(p.join(contents.path, 'MacOS')).createSync();
    plant('K.app/Contents/Resources/idb-companion');
    plant('checkout/macos/Vendor/idb-companion');

    final found = IdbCompanionLocator(
      resolvedExecutable: p.join(contents.path, 'MacOS', 'karmashala'),
      workingDirectory: p.join(tmp.path, 'checkout'),
      environment: const {},
    ).locate();

    expect(found!.source, IdbCompanionSource.bundled);
    expect(found.executable, contains('K.app/Contents/Resources'));
  });

  test('falls back to the checkout, for anyone running from source', () {
    plant('checkout/macos/Vendor/idb-companion');

    final found = IdbCompanionLocator(
      resolvedExecutable: p.join(tmp.path, 'nowhere', 'app'),
      workingDirectory: p.join(tmp.path, 'checkout'),
      environment: const {},
    ).locate();

    expect(found!.source, IdbCompanionSource.workingTree);
  });

  test('accepts one on PATH, and records that it is not the pinned build', () {
    // Someone's Homebrew install. Refusing it would be worse than using it,
    // but its version is whatever they happen to have.
    final exe = plant('brew/bin');

    final found = IdbCompanionLocator(
      resolvedExecutable: p.join(tmp.path, 'nowhere', 'app'),
      workingDirectory: p.join(tmp.path, 'nowhere'),
      environment: {'PATH': '${p.dirname(exe)}:/usr/bin'},
    ).locate();

    expect(found!.source, IdbCompanionSource.path);
  });

  test('a companion with no Resources beside it is not accepted', () {
    // It resolves guest binaries as dirname(argv[0]) + "/Resources". Without
    // them the accessibility path fails outright — no element tree — while
    // video and touch still work, which is a confusing half-broken state.
    final exe = plant('brew/bin', withResources: false);

    final found = IdbCompanionLocator(
      resolvedExecutable: p.join(tmp.path, 'nowhere', 'app'),
      workingDirectory: p.join(tmp.path, 'nowhere'),
      environment: {'PATH': p.dirname(exe)},
    ).locate();

    expect(found, isNull);
  });

  test('no companion anywhere is null, not an exception', () {
    // Windows, Linux, and Intel Macs all land here, and the pane degrades to
    // what simctl alone can do.
    expect(
      IdbCompanionLocator(
        resolvedExecutable: p.join(tmp.path, 'nowhere', 'app'),
        workingDirectory: p.join(tmp.path, 'nowhere'),
        environment: const {'PATH': '/does/not/exist'},
      ).locate(),
      isNull,
    );
  });

  group('the socket path', () {
    test('stays well inside the 104-byte cap', () {
      // Measured: a path longer than the cap makes the companion refuse with
      // `NIOCore.SocketAddressError error 3` and never bind — after it has
      // already logged that it was starting.
      final path = idbSocketPathFor(
        '959BEFD8-241E-4486-AA54-7E73CC7F03CD',
        temporaryDirectory: '/tmp',
      );

      expect(path.length, lessThan(104));
      expect(path, '/tmp/idb-959befd8.sock');
    });

    test('two simulators do not share a socket', () {
      expect(
        idbSocketPathFor('AAAAAAAA-1111-2222-3333-444444444444'),
        isNot(idbSocketPathFor('BBBBBBBB-1111-2222-3333-444444444444')),
      );
    });
  });
}
