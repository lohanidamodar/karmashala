import 'dart:io';

import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:test/test.dart';

/// Where a socket goes when the path its owner chose is too long to bind.
///
/// Found on 2026-09-16: a debug run with its data directory inside the repo put
/// the RPC socket at 125 bytes, macOS refused it, and the app withheld every
/// privileged tool from its agents. Each platform's answer is checked from any
/// host by passing the platform in; the last group binds a real socket on this
/// one.
void main() {
  String pathOf(int bytes, {String prefix = '/Users/x/'}) {
    const suffix = '.sock';
    return '$prefix${'a' * (bytes - prefix.length - suffix.length)}$suffix';
  }

  const mac = {'TMPDIR': '/var/folders/bc/5fhr3gyn01x7mq3v7p3ffrvm0000gn/T/'};

  group('a path that fits stays where it was put', () {
    test('up to the byte the system binds, and not one past it', () {
      // 103 bound and 104 was refused, measured on macOS 26.
      expect(
        locateSocket(pathOf(103), operatingSystem: 'macos', environment: mac),
        isA<PreferredSocketLocation>(),
      );
      expect(
        locateSocket(pathOf(104), operatingSystem: 'macos', environment: mac),
        isA<FallbackSocketLocation>(),
      );
    });

    test('every default install measured fits, so nobody\'s socket moves', () {
      for (final (os, path) in [
        (
          'macos',
          '/Users/dlohani/Library/Application Support/com.popupbits.karmashala/ipc/rpc.sock',
        ),
        (
          'windows',
          r'C:\Users\dlohani\AppData\Roaming\com.popupbits\karmashala\ipc\rpc.sock',
        ),
        (
          'linux',
          '/home/dlohani/.local/share/com.popupbits.karmashala/ipc/rpc.sock',
        ),
      ]) {
        expect(
          locateSocket(path, operatingSystem: os, environment: const {}),
          isA<PreferredSocketLocation>(),
          reason: os,
        );
      }
    });

    test('the limit is bytes, not characters', () {
      // 34 Devanagari letters are 34 characters and 102 bytes.
      final name = 'न' * 34;
      final path = '/Users/$name/k.sock';
      expect(path.length, lessThan(103));
      expect(
        locateSocket(path, operatingSystem: 'macos', environment: mac),
        isA<FallbackSocketLocation>(),
      );
    });
  });

  group('a path that does not fit moves somewhere short and private', () {
    test('on macOS, under the per-user TMPDIR', () {
      final location =
          locateSocket(pathOf(125), operatingSystem: 'macos', environment: mac)
              as FallbackSocketLocation;
      expect(
        location.directory,
        '/var/folders/bc/5fhr3gyn01x7mq3v7p3ffrvm0000gn/T/karmashala',
      );
      expect(location.path, startsWith('${location.directory}/'));
      expect(
        location.path.split('/').last,
        matches(RegExp(r'^[0-9a-f]{12}\.sock$')),
      );
      expect(location.sharedParent, isFalse);
      expect(location.reason, contains('125 bytes'));
    });

    test('on Linux, under XDG_RUNTIME_DIR when the session has one', () {
      final location =
          locateSocket(
                pathOf(130, prefix: '/home/x/'),
                operatingSystem: 'linux',
                environment: const {'XDG_RUNTIME_DIR': '/run/user/1000'},
              )
              as FallbackSocketLocation;
      expect(location.directory, '/run/user/1000/karmashala');
      expect(location.sharedParent, isFalse);
    });

    test(
      'on Linux without one, in /tmp under a name that says whose it is',
      () {
        final location =
            locateSocket(
                  pathOf(130, prefix: '/home/x/'),
                  operatingSystem: 'linux',
                  environment: const {},
                  currentUid: () => 1000,
                )
                as FallbackSocketLocation;
        expect(location.directory, '/tmp/karmashala-1000');
        expect(
          location.sharedParent,
          isTrue,
          reason: 'anyone can write to /tmp',
        );
      },
    );

    test('on Windows, under LOCALAPPDATA, spelled with backslashes', () {
      final location =
          locateSocket(
                r'C:\Users\dlohani\Documents\projects\popupbits-ai-workspace'
                r'\projects\karmashala-app\karmashala-app\build\debug-data'
                r'\ipc\rpc.sock',
                operatingSystem: 'windows',
                environment: const {
                  'LOCALAPPDATA': r'C:\Users\dlohani\AppData\Local',
                },
              )
              as FallbackSocketLocation;
      expect(
        location.directory,
        r'C:\Users\dlohani\AppData\Local\karmashala\s',
      );
      expect(location.path, startsWith('${location.directory}\\'));
      expect(location.limit, 107);
    });

    test(
      'one data directory always gets the same socket, and two never share',
      () {
        String place(String preferred) => locateSocket(
          preferred,
          operatingSystem: 'macos',
          environment: mac,
        ).path!;
        final real = pathOf(120, prefix: '/Users/x/real/');
        final debug = pathOf(120, prefix: '/Users/x/debug/');
        expect(place(real), place(real));
        expect(place(real), isNot(place(debug)));
      },
    );
  });

  group('nowhere to put it is said, not attempted', () {
    test('when the machine offers no short private directory', () {
      final location = locateSocket(
        pathOf(125),
        operatingSystem: 'macos',
        environment: const {},
      );
      expect(location, isA<UnplaceableSocket>());
      expect(location.path, isNull);
      expect((location as UnplaceableSocket).reason, contains('125 bytes'));
    });

    test('when even the fallback would be too long', () {
      final location =
          locateSocket(
                pathOf(125),
                operatingSystem: 'macos',
                environment: {'TMPDIR': '/${'t' * 95}'},
              )
              as UnplaceableSocket;
      expect(location.reason, contains('even the short fallback'));
      expect(location.reason, contains('at most 103'));
    });

    test('a relative directory is not somewhere to put a socket', () {
      expect(
        locateSocket(
          pathOf(125),
          operatingSystem: 'macos',
          environment: const {'TMPDIR': 'tmp'},
        ),
        isA<UnplaceableSocket>(),
      );
    });
  });

  group('the fallback directory is proven private before it is trusted', () {
    late Directory parent;
    setUp(() => parent = Directory.systemTemp.createTempSync('sl'));
    tearDown(() => parent.deleteSync(recursive: true));

    FallbackSocketLocation at(String directory, {bool shared = false}) =>
        FallbackSocketLocation(
          path: '$directory/abc.sock',
          directory: directory,
          preferred: '/long',
          preferredBytes: 200,
          limit: 103,
          sharedParent: shared,
        );

    test('it is created owner-only', () async {
      final dir = '${parent.path}/private';
      expect(await prepareFallbackSocketDirectory(at(dir)), isNull);
      expect(Directory(dir).statSync().mode & 0x1ff, 0x1c0 /* 0700 */);
    }, testOn: 'posix');

    test('in a shared parent, a symlink is refused', () async {
      final target = Directory('${parent.path}/elsewhere')..createSync();
      final link = '${parent.path}/karmashala-1000';
      Link(link).createSync(target.path);
      final refused = await prepareFallbackSocketDirectory(
        at(link, shared: true),
      );
      expect(refused, contains('symlink'));
    }, testOn: 'posix');

    test(
      'in a shared parent, a directory another account owns is refused',
      () async {
        final dir = '${parent.path}/karmashala-1000';
        final refused = await prepareFallbackSocketDirectory(
          at(dir, shared: true),
          // Somebody else: whoever this test runs as, it is not uid 999999.
          currentUid: () => 999999,
        );
        expect(refused, contains('not to this account'));
      },
      testOn: 'posix',
    );
  });

  group('on this machine', () {
    test(
      'a path too long to bind is refused, and its fallback binds and answers',
      () async {
        final base = Directory.systemTemp.createTempSync('sl');
        addTearDown(() => base.deleteSync(recursive: true));
        final deep = Directory('${base.path}/${'d' * 60}/${'e' * 40}')
          ..createSync(recursive: true);
        final preferred = '${deep.path}/rpc.sock';
        expect(
          preferred.length,
          greaterThan(maxSocketPathBytes(Platform.operatingSystem)),
        );

        // The failure this replaces, measured rather than assumed.
        await expectLater(
          ServerSocket.bind(localSocketAddress(preferred), 0),
          throwsA(isA<SocketException>()),
        );

        final location = locateSocket(preferred) as FallbackSocketLocation;
        expect(await prepareFallbackSocketDirectory(location), isNull);
        final server = await LocalRpcServer.bind(
          location.path,
          (line) => 'echo:$line',
        );
        addTearDown(server.close);
        expect(await LocalRpcClient.call(location.path, 'hi'), 'echo:hi');
      },
      testOn: 'mac-os || linux',
    );
  });
}
