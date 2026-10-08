import 'dart:io';

import 'package:karmashala_host/src/ssh/deploy/host_bundles.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;
import 'package:karmashala_ssh_host/host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Where the server finds the host bundles it deploys to boxes (slice 5d):
/// never a client's app bundle — its own folders, in a stated order, and a
/// refusal that names them when the one a box needs is in none.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('ks_bundles_'));
  tearDown(() => temp.deleteSync(recursive: true));

  HostPlatform linux(String arch) => HostPlatform(
    operatingSystem: 'linux',
    architecture: arch,
    libc: HostLibc.glibc,
    observedAt: DateTime.utc(2026, 9, 27),
  );

  File bundle(String folder, String name) =>
      File(p.join(temp.path, folder, name))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(64, 1));

  test('the operator\'s folders first, then the data folder, then beside '
      'the server\'s own bundle', () async {
    bundle('named', 'karmashala_host-1.30.0-linux-x64.tar.gz');
    bundle('data/host-bundles', 'karmashala_host-1.29.0-linux-x64.tar.gz');
    bundle('data/host-bundles', 'karmashala_host-1.29.0-linux-arm64.tar.gz');
    bundle('app', 'karmashala_host-1.28.0-macos-arm64.tar.gz');
    final source = serverHostBundles(
      dataDirectory: p.join(temp.path, 'data'),
      environment: {kHostBundlesVariable: p.join(temp.path, 'named')},
      executable: p.join(temp.path, 'app', 'host', 'bin', 'karmashala_host'),
      workingDirectory: temp.path,
    );
    expect((await source.binaryFor(linux('x64')))!.version, '1.30.0');
    expect((await source.binaryFor(linux('arm64')))!.version, '1.29.0');
    final mac = HostPlatform(
      operatingSystem: 'darwin',
      architecture: 'arm64',
      libc: HostLibc.unknown,
      observedAt: DateTime.utc(2026, 9, 27),
    );
    expect((await source.binaryFor(mac))!.version, '1.28.0');
    expect(await source.availableTargets(), [
      'linux-arm64',
      'linux-x64',
      'macos-arm64',
    ]);
    final said = source.describeSearch();
    expect(said, contains(p.join(temp.path, 'named')));
    expect(said, contains(p.join(temp.path, 'data', 'host-bundles')));
    expect(said, contains(p.join(temp.path, 'app', 'host')));
    expect(said, contains(p.join(temp.path, 'app')));
  });

  test('an old release left in the data folder never shadows the install '
      'folder\'s own host', () async {
    // The owner's box: `<data dir>/host-bundles` kept 1.29.0 and 1.26.3 from
    // an earlier install, searched before the install folder holding the
    // server's own version — and every reinstall deployed 1.29.0.
    bundle('data/host-bundles', 'karmashala_host-1.29.0-linux-x64.tar.gz');
    bundle('data/host-bundles', 'karmashala_host-1.26.3-linux-x64.tar.gz');
    bundle('app', 'karmashala_host-$kHostVersion-linux-x64.tar.gz');
    final source = serverHostBundles(
      dataDirectory: p.join(temp.path, 'data'),
      environment: const {},
      executable: p.join(temp.path, 'app', 'host', 'bin', 'karmashala_host'),
      workingDirectory: temp.path,
    );

    final binary = (await source.binaryFor(linux('x64')))!;

    expect(binary.version, kHostVersion);
    expect(binary.source, startsWith(p.join(temp.path, 'app')));
    expect(binary.olderBundlesIn, p.join(temp.path, 'data', 'host-bundles'));
    expect(
      Directory(p.join(temp.path, 'data', 'host-bundles')).listSync(),
      hasLength(2),
      reason: 'nothing is deleted',
    );
  });

  test('a debug run finds the repository\'s server/build', () async {
    File(p.join(temp.path, 'server', 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: karmashala_host\n');
    bundle('server/build', 'karmashala_host-0.0.0-linux-x64.tar.gz');
    final source = serverHostBundles(
      dataDirectory: p.join(temp.path, 'data'),
      environment: const {},
      executable: '/usr/local/bin/dart',
      workingDirectory: p.join(temp.path, 'app'),
    );
    expect((await source.binaryFor(linux('x64')))!.version, '0.0.0');
  });

  test('a box whose bundle is nowhere gets nothing, and the words say where '
      'the server looked', () async {
    final source = serverHostBundles(
      dataDirectory: p.join(temp.path, 'data'),
      environment: const {},
      executable: '/usr/local/bin/dart',
      workingDirectory: temp.path,
    );
    expect(await source.binaryFor(linux('riscv64')), isNull);
    expect(source.describeSearch(), contains('host-bundles'));
  });
}
