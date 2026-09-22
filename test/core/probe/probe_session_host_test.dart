import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:karmashala/src/features/ssh/application/host_session_providers.dart';
import 'package:karmashala/src/features/ssh/application/host_sessions.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_local_ipc/socket_location.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:path/path.dart' as p;

import '../../features/ssh/fake_host_box.dart';

/// A probe never meets the owner's session host (PROJECT.md §23).
///
/// The local host's socket, lock, sessions and store are per *user*, not per
/// data folder, so a probe with host-backed panes would have attached to the
/// owner's host: its sessions in the probe's lists, and one click from ending
/// them. A probe runs a host of its own under its data folder instead, started
/// from the same binary with `KARMASHALA_HOST_DIR` naming that folder.
void main() {
  late Directory data;

  setUp(() => data = Directory.systemTemp.createTempSync('ksp'));
  tearDown(() {
    try {
      data.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node can still be held on Windows.
    }
  });

  ProviderContainer containerFor(ProbeMode probe) {
    final container = ProviderContainer(
      overrides: [probeModeProvider.overrideWithValue(probe)],
    );
    addTearDown(container.dispose);
    return container;
  }

  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  test('a probe keeps its session host under its own data folder', () {
    final access = containerFor(
      ProbeMode(enabled: true, dataDirectory: data.path),
    ).read(localHostSessionAccessProvider)!;
    final home = p.join(data.path, 'host');

    expect(access.paths.directory.path, home);
    for (final path in [
      access.paths.lockPath,
      access.paths.logPath,
      access.paths.sessionsDirectory,
      access.paths.storeDirectory.path,
    ]) {
      expect(p.isWithin(data.path, path), isTrue, reason: path);
    }
    // The socket sits beside them — or, too long to bind there, at a name
    // hashed from that path, exactly as the `ipc/` socket falls back.
    switch (access.paths.socketLocation) {
      case PreferredSocketLocation(:final path):
        expect(p.isWithin(data.path, path), isTrue);
      case FallbackSocketLocation(:final path, :final preferred):
        expect(p.basename(path), socketFileNameFor(preferred));
      case UnplaceableSocket(:final reason):
        fail(reason);
    }

    // The `serve` it starts is told the same folder, and reads it back there.
    expect(access.serveEnvironment, {kHostDirectoryEnvironmentVariable: home});
    expect(
      HostPaths.resolve(environment: access.serveEnvironment).directory.path,
      home,
    );
  }, skip: desktop ? null : 'no local host off the desktop');

  test('a probe never looks at the socket the real app uses', () {
    final real = containerFor(
      ProbeMode.off,
    ).read(localHostSessionAccessProvider)!;
    final probe = containerFor(
      ProbeMode(enabled: true, dataDirectory: data.path),
    ).read(localHostSessionAccessProvider)!;

    expect(probe.socketPath, isNot(real.socketPath));
    expect(probe.paths.lockPath, isNot(real.paths.lockPath));
    expect(probe.paths.sessionsDirectory, isNot(real.paths.sessionsDirectory));
  }, skip: desktop ? null : 'no local host off the desktop');

  test("the real app's host is exactly where it always was", () {
    final access = containerFor(
      ProbeMode.off,
    ).read(localHostSessionAccessProvider)!;
    // Found after an upgrade: the per-user default, and no variable handed to
    // the `serve` it starts, so an already-running host is the one it finds.
    expect(access.paths.directory.path, HostPaths.resolve().directory.path);
    if (Platform.isWindows &&
        !Platform.environment.containsKey(kHostDirectoryEnvironmentVariable)) {
      expect(
        access.paths.directory.path,
        '${Platform.environment['USERPROFILE']}/.karmashala',
      );
    }
    expect(access.serveEnvironment, isNull);
  }, skip: desktop ? null : 'no local host off the desktop');

  test('a probe with no data folder gets no host, never the real one', () {
    expect(
      containerFor(ProbeMode.on).read(localHostSessionAccessProvider),
      isNull,
    );
  });

  test('a probe asks its own socket, and finds its own host there', () async {
    final access = containerFor(
      ProbeMode(enabled: true, dataDirectory: data.path),
    ).read(localHostSessionAccessProvider)!;
    access.paths.ensureDirectory();

    // A host in the probe's folder, as the `serve` it starts would bind.
    final registry = SessionRegistry(launcher: FakePtyLauncher());
    final server = HostServer(registry: registry, ptyLibrary: 'fake');
    final listener = await UnixSocketHostListener.bind(access.socketPath);
    final subscription = server.listen(listener);
    addTearDown(() async {
      await subscription.cancel();
      await listener.close();
      await registry.shutdown();
    });

    // `observe` starts nothing, so this never touches a real `serve`.
    final reading = await access.observe();
    expect(reading.status, HostDeploymentStatus.ready);
  }, skip: desktop ? null : 'no local host off the desktop');

  group('an SSH machine', () {
    test("a probe's panes are given no session host there", () {
      final container = containerFor(
        ProbeMode(enabled: true, dataDirectory: data.path),
      );
      expect(container.read(hostSessionAccessLookupProvider)(boxHost), isNull);
    });

    test("a probe never lists or ends the sessions held there", () async {
      final service = containerFor(
        ProbeMode(enabled: true, dataDirectory: data.path),
      ).read(hostSessionsServiceProvider);

      await expectLater(
        service.list(boxHost),
        throwsA(
          isA<HostSessionsUnavailable>().having(
            (e) => e.message,
            'message',
            contains('probe'),
          ),
        ),
      );
      await expectLater(
        service.end(boxHost, 'karmashala_h1_p1'),
        throwsA(isA<HostSessionsUnavailable>()),
      );
    });
  });
}
