import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;
import 'package:karmashala_ssh_host/host.dart';

/// Real files in a real directory, because what is under test is a directory
/// listing and the order the filesystem hands it back in.
void main() {
  late Directory release;
  late Directory build;

  setUp(() {
    release = Directory.systemTemp.createTempSync('karmashala_release');
    build = Directory.systemTemp.createTempSync('karmashala_build');
  });

  tearDown(() {
    release.deleteSync(recursive: true);
    build.deleteSync(recursive: true);
  });

  void give(Directory directory, String name, {int bytes = 8}) =>
      File('${directory.path}/$name').writeAsBytesSync(Uint8List(bytes));

  HostPlatform machine(String targetKey) {
    final parts = targetKey.split('-');
    return HostPlatform(
      operatingSystem: parts.first,
      architecture: parts.last,
      libc: HostLibc.glibc,
      observedAt: DateTime.utc(2026, 9, 10),
    );
  }

  group('a bundle tarball, which is what every current build ships', () {
    test('it is matched, and says it needs unpacking', () async {
      give(release, 'karmashala_host-1.21.0-linux-x64.tar.gz', bytes: 30);

      final binary = await DirectoryHostBinaries([
        release,
      ]).binaryFor(machine('linux-x64'));

      expect(binary, isNotNull);
      expect(binary!.version, '1.21.0');
      expect(binary.isBundleArchive, isTrue);
      expect(binary.source, endsWith('.tar.gz'));
    });

    test('the suffix is not mistaken for part of the architecture', () async {
      give(release, 'karmashala_host-1.21.0-linux-arm64.tar.gz');

      expect(
        await DirectoryHostBinaries([
          release,
        ]).binaryFor(machine('linux-arm64')),
        isNotNull,
      );
      expect(await DirectoryHostBinaries([release]).availableTargets(), [
        'linux-arm64',
      ]);
    });

    test(
      'at one version the bundle beats the bare file, which has no sqlite',
      () async {
        give(release, 'karmashala_host-1.21.0-linux-x64', bytes: 10);
        give(release, 'karmashala_host-1.21.0-linux-x64.tar.gz', bytes: 20);

        final binary = await DirectoryHostBinaries([
          release,
        ]).binaryFor(machine('linux-x64'));

        expect(binary!.isBundleArchive, isTrue);
        expect(binary.length, 20);
      },
    );

    test('an older bundle beats a newer bare file, which has no sqlite', () async {
      // Shape before version, and this upgrade is why: the installer deletes
      // nothing, so a bare file from an earlier release outlives it. Ranking by
      // version would deploy a pre-store host that answers `hello` and reads as
      // `ready` while being unable to hold a store at all.
      give(release, 'karmashala_host-1.20.0-linux-x64.tar.gz', bytes: 20);
      give(release, 'karmashala_host-1.21.0-linux-x64', bytes: 10);

      final binary = await DirectoryHostBinaries([
        release,
      ]).binaryFor(machine('linux-x64'));

      expect(binary!.isBundleArchive, isTrue);
      expect(binary.version, '1.20.0');
    });

    test('the newest still wins among bundles', () async {
      give(release, 'karmashala_host-1.20.0-linux-x64.tar.gz', bytes: 10);
      give(release, 'karmashala_host-1.21.0-linux-x64.tar.gz', bytes: 20);

      final binary = await DirectoryHostBinaries([
        release,
      ]).binaryFor(machine('linux-x64'));

      expect(binary!.version, '1.21.0');
    });

    test('the bytes are read only when asked for', () async {
      give(release, 'karmashala_host-1.21.0-linux-x64.tar.gz', bytes: 30);

      final binary = await DirectoryHostBinaries([
        release,
      ]).binaryFor(machine('linux-x64'));

      expect(binary!.length, 30, reason: 'the size comes from a stat');
      expect(await binary.readBytes(), hasLength(30));
    });
  });

  group('picking a binary', () {
    test(
      'the newer of two versions is taken, and the older is left where it is',
      () async {
        give(release, 'karmashala_host-1.20.0-linux-x64', bytes: 10);
        give(release, 'karmashala_host-1.20.1-linux-x64', bytes: 20);

        final binary = await DirectoryHostBinaries([
          release,
        ]).binaryFor(machine('linux-x64'));

        expect(binary!.version, '1.20.1');
        expect(binary.source, endsWith('karmashala_host-1.20.1-linux-x64'));
        expect(binary.length, 20);
        expect(binary.candidates, 2);
        // The installer copies the Release directory wholesale; nothing here is
        // entitled to prune it.
        expect(release.listSync(), hasLength(2));
      },
    );

    test('versions are compared as numbers, not as text', () async {
      // The bug in one line: sorted as strings, 1.9.0 comes last of these.
      give(release, 'karmashala_host-1.9.0-linux-x64');
      give(release, 'karmashala_host-1.10.0-linux-x64');
      give(release, 'karmashala_host-1.20.1-linux-x64');

      final binary = await DirectoryHostBinaries([
        release,
      ]).binaryFor(machine('linux-x64'));

      expect(binary!.version, '1.20.1');
      expect(binary.candidates, 3);
    });

    test('an unversioned file loses to any versioned one', () async {
      give(release, 'karmashala_host-linux-x64');
      give(release, 'karmashala_host-0.1.0-linux-x64');

      final binary = await DirectoryHostBinaries([
        release,
      ]).binaryFor(machine('linux-x64'));

      expect(binary!.version, '0.1.0');
      expect(binary.candidates, 2);
    });

    test(
      'an unversioned file on its own is still a binary, and says so',
      () async {
        give(release, 'karmashala_host-linux-x64');

        final binary = await DirectoryHostBinaries([
          release,
        ]).binaryFor(machine('linux-x64'));

        expect(binary!.version, 'unversioned');
        expect(binary.candidates, 1);
      },
    );

    test(
      'another os or arch is never picked, however high its version',
      () async {
        give(release, 'karmashala_host-9.9.9-linux-arm64');
        give(release, 'karmashala_host-9.9.9-darwin-arm64');
        give(release, 'karmashala_host-1.0.0-linux-x64');

        final binaries = DirectoryHostBinaries([release]);
        final binary = await binaries.binaryFor(machine('linux-x64'));

        expect(binary!.version, '1.0.0');
        expect(binary.source, endsWith('karmashala_host-1.0.0-linux-x64'));
        expect(binary.candidates, 1);
        expect(await binaries.availableTargets(), [
          'darwin-arm64',
          'linux-arm64',
          'linux-x64',
        ]);
      },
    );

    test(
      'every directory is searched: a later one with a newer host wins',
      () async {
        give(release, 'karmashala_host-1.19.0-linux-x64');
        give(release, 'karmashala_host-1.20.1-linux-x64');
        give(build, 'karmashala_host-2.0.0-linux-x64');

        final binary = await DirectoryHostBinaries([
          release,
          build,
        ], preferredVersion: '9.9.9').binaryFor(machine('linux-x64'));

        expect(binary!.version, '2.0.0');
        expect(binary.candidates, 3);
      },
    );

    test('a directory with nothing for this target has no binary', () async {
      give(release, 'karmashala_host-1.20.1-linux-arm64');
      give(release, 'karmashala_host.exe');

      expect(
        await DirectoryHostBinaries([release]).binaryFor(machine('linux-x64')),
        isNull,
      );
      // A directory that is not there is not a failure either.
      expect(
        await DirectoryHostBinaries([
          Directory('${release.path}/absent'),
        ]).binaryFor(machine('linux-x64')),
        isNull,
      );
    });
  });

  group('across folders', () {
    // The owner's drop folder held 1.29.0 from an earlier install, searched
    // before the install folder holding 1.34.1, and every reinstall put
    // 1.29.0 back: the first folder with any match won outright.
    test('two folders, the older one first: the newer one wins', () async {
      give(release, 'karmashala_host-1.29.0-linux-x64.tar.gz', bytes: 10);
      give(release, 'karmashala_host-1.26.3-linux-x64.tar.gz', bytes: 11);
      give(build, 'karmashala_host-1.34.1-linux-x64.tar.gz', bytes: 20);

      final binary = await DirectoryHostBinaries([
        release,
        build,
      ], preferredVersion: '9.9.9').binaryFor(machine('linux-x64'));

      expect(binary!.version, '1.34.1');
      expect(binary.source, startsWith(build.path));
      expect(binary.folder, build.path);
      expect(binary.candidates, 3);
      // Nothing is deleted, and the folder whose bundles were passed over is
      // named for a person to tidy.
      expect(release.listSync(), hasLength(2));
      expect(binary.olderBundlesIn, release.path);
    });

    test('the same version in both: the first folder wins', () async {
      give(release, 'karmashala_host-1.34.1-linux-x64.tar.gz', bytes: 10);
      give(build, 'karmashala_host-1.34.1-linux-x64.tar.gz', bytes: 20);

      final binary = await DirectoryHostBinaries([
        release,
        build,
      ], preferredVersion: '9.9.9').binaryFor(machine('linux-x64'));

      expect(binary!.source, startsWith(release.path));
      expect(binary.length, 10);
      expect(binary.olderBundlesIn, isNull);
    });

    test(
      'an exact match for the server\'s version beats a newer one',
      () async {
        give(build, 'karmashala_host-99.0.0-linux-x64.tar.gz', bytes: 20);
        give(release, 'karmashala_host-98.0.0-linux-x64.tar.gz', bytes: 30);
        give(
          release,
          'karmashala_host-$kHostVersion-linux-x64.tar.gz',
          bytes: 10,
        );

        final binary = await DirectoryHostBinaries([
          build,
          release,
        ]).binaryFor(machine('linux-x64'));

        expect(binary!.version, kHostVersion);
        expect(binary.source, startsWith(release.path));
      },
    );

    test('a bare binary never beats an archive, from any folder', () async {
      give(release, 'karmashala_host-$kHostVersion-linux-x64', bytes: 10);
      give(release, 'karmashala_host-99.0.0-linux-x64', bytes: 11);
      give(build, 'karmashala_host-1.0.0-linux-x64.tar.gz', bytes: 20);

      final binary = await DirectoryHostBinaries([
        release,
        build,
      ]).binaryFor(machine('linux-x64'));

      expect(binary!.isBundleArchive, isTrue);
      expect(binary.version, '1.0.0');
    });
  });

  test(
    'a machine with no binary in this build still answers noBinary',
    () async {
      give(release, 'karmashala_host-1.20.1-linux-arm64');

      final deployment = await HostDeployer(
        target: _StubTarget(),
        binaries: DirectoryHostBinaries([release]),
        clock: () => DateTime.utc(2026, 9, 10),
      ).deploy();

      expect(deployment.status, HostDeploymentStatus.noBinary);
      expect(deployment.reason, contains('linux-x64'));
      expect(deployment.reason, contains('linux-arm64'));
    },
  );
}

/// Answers `uname` and nothing else: a deploy that gets past the binary check
/// here has already failed the test.
class _StubTarget implements HostDeployTarget {
  @override
  String get address => 'stub.example';

  @override
  Future<RemoteRun> run(String command) async =>
      RemoteRun(0, 'Linux\nx86_64\nldd (GNU libc) 2.43\n', '');

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async =>
      fail('nothing should be uploaded when this build has no binary');

  @override
  Future<RemoteChannel> exec(String command) async =>
      fail('nothing should be started when this build has no binary');
}
