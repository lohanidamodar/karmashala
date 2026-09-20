import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

void main() {
  group('where the socket lives', () {
    test('a Windows host is rooted at USERPROFILE, whatever HOME says', () {
      final paths = HostPaths.resolve(
        environment: {
          'USERPROFILE': r'C:\Users\dlohani',
          // A WSL shell or an MSYS tool leaves this behind, and the host's
          // directory must not follow it somewhere the app cannot reach.
          'HOME': '/home/dlohani',
          'XDG_RUNTIME_DIR': '/run/user/1000',
        },
      );
      if (!Platform.isWindows) {
        expect(paths.directory.path, '/home/dlohani/.karmashala');
        return;
      }
      expect(paths.directory.path, r'C:\Users\dlohani/.karmashala');
      expect(paths.socketPath, endsWith('host.sock'));
    });

    test(
      'a POSIX host prefers the runtime dir, and only when it exists',
      () {
        // Skipped rather than faked: the branch reads the real filesystem.
        final missing = HostPaths.resolve(
          environment: {
            'XDG_RUNTIME_DIR': '/nonexistent-runtime-dir',
            'HOME': '/home/x',
          },
        );
        expect(missing.directory.path, '/home/x/.karmashala');

        final present = HostPaths.resolve(
          environment: {
            'XDG_RUNTIME_DIR': Directory.systemTemp.path,
            'HOME': '/home/x',
          },
        );
        expect(
          present.directory.path,
          '${Directory.systemTemp.path}/karmashala',
        );
      },
      skip: Platform.isWindows
          ? 'XDG_RUNTIME_DIR is not consulted on Windows'
          : null,
    );

    test('nothing in the directory is named without the directory', () {
      final paths = HostPaths(Directory('/tmp/karmashala-test'));
      expect(paths.socketPath, startsWith(paths.directory.path));
      expect(paths.lockPath, startsWith(paths.directory.path));
      expect(paths.logPath, startsWith(paths.directory.path));
      expect(paths.binDirectory, startsWith(paths.directory.path));
    });
  });

  group('the owner-only boundary', () {
    test('is applied to a real directory and reported as applied', () async {
      final dir = Directory.systemTemp.createTempSync('karmashala-host-acl');
      addTearDown(() => dir.deleteSync(recursive: true));
      final refusal = await HostPaths(dir).restrictToCurrentUser();
      expect(
        refusal,
        isNull,
        reason: 'the boundary is a prerequisite, not a best effort',
      );
    });

    test('names the directory when it cannot be established', () async {
      final refusal = await HostPaths(
        Directory(
          '${Directory.systemTemp.path}/karmashala-host-absent-${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).restrictToCurrentUser();
      // A refusal, not a silent success, naming what a person must look at.
      expect(refusal, isNotNull);
      expect(refusal, contains('karmashala-host-absent'));
    });
  });
}
