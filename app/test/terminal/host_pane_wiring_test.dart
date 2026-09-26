import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_host/karmashala_host.dart';

/// Which pane the *real* factory builds, so "the setting decides" is asserted
/// rather than assumed.
///
/// The whole point of the default is that with it off nothing changes, and the
/// only way to know that is to open a pane through the same provider the app
/// does and look at what came back.
void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('ksw');
  });
  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node can still be held on Windows.
    }
  });

  /// An access in a folder of its own with no binary to start, so a pane that
  /// measures it can neither reach nor start the host of the person running
  /// the tests.
  LocalHostSessionAccess inertAccess() => LocalHostSessionAccess(
    paths: HostPaths(Directory('${home.path}/.k'))..ensureDirectory(),
    executable: LocalHostExecutable(
      executableDirectory: '${home.path}/absent',
      repositoryRoot: '${home.path}/absent',
    ),
  );

  ProviderContainer containerWith({
    required bool setting,
    LocalHostSessionAccess? access,
  }) => ProviderContainer(
    overrides: [
      hostBackedLocalPanesProvider.overrideWithValue(setting),
      localHostSessionAccessProvider.overrideWithValue(access),
    ],
  );

  TerminalInstance openLocalPane(ProviderContainer container) =>
      container.read(terminalInstanceFactoryProvider)(
        id: 'p1',
        profile: const TerminalProfile(
          id: 'cmd',
          label: 'Command Prompt',
          shell: TerminalShell.commandPrompt,
        ),
      );

  test('with the setting off, a local pane is what it has always been', () {
    final container = containerWith(setting: false, access: inertAccess());
    addTearDown(container.dispose);
    final pane = openLocalPane(container);
    addTearDown(pane.dispose);
    expect(pane, isNot(isA<HostTerminalInstance>()));
  });

  test('with the setting on, a local pane belongs to the session host', () {
    final container = containerWith(setting: true, access: inertAccess());
    addTearDown(container.dispose);
    final pane = openLocalPane(container);
    addTearDown(pane.dispose);
    expect(pane, isA<HostTerminalInstance>());
    // The launch is the one a flutter_pty pane would have spawned: the profile
    // decides the command, and the setting decides only whose child it is. Off
    // Windows a Command Prompt profile opens the login shell, as it always has.
    expect(
      (pane as HostTerminalInstance).launch.executable,
      Platform.isWindows
          ? 'cmd.exe'
          : Platform.environment['SHELL'] ?? '/bin/bash',
    );
  });

  test('with the setting on and no host to reach, nothing changes either', () {
    // A companion build, or any platform with no binary to run: the provider
    // answers null and the pane falls through to the path that always worked,
    // rather than to a pane that cannot start.
    final container = containerWith(setting: true, access: null);
    addTearDown(container.dispose);
    final pane = openLocalPane(container);
    addTearDown(pane.dispose);
    expect(pane, isNot(isA<HostTerminalInstance>()));
  });

  group('an older host an earlier app left running', () {
    /// A real host over a real socket, of a build this app does not ship,
    /// holding one running session; and an access that has looked at it.
    Future<LocalHostSessionAccess> lookedAtOutdatedHost() async {
      final paths = HostPaths(Directory('${home.path}/.k'))..ensureDirectory();
      File(
        '${home.path}/${LocalHostExecutable.fileName}',
      ).writeAsStringSync('this app\'s build');
      final launcher = FakePtyLauncher();
      final registry = SessionRegistry(launcher: launcher);
      final server = HostServer(
        registry: registry,
        ptyLibrary: 'fake',
        build: 'an-earlier-build',
      );
      final listener = await UnixSocketHostListener.bind(paths.socketPath);
      final subscription = server.listen(listener);
      addTearDown(() async {
        await subscription.cancel();
        await listener.close();
        for (final handle in launcher.handles) {
          handle.finish(0);
        }
        await registry.shutdown();
      });
      registry.open(
        hostSessionIdFor(paneId: 'kept'),
        const PtySpawnRequest(argv: ['cmd.exe']),
      );
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        startServe: (_) async => throw StateError('nothing may start'),
        stopServe: (_, {required force}) async =>
            throw StateError('a host with a running session was stopped'),
      );
      expect((await access.observe()).hostOutdated, isTrue);
      return access;
    }

    test('a new pane runs in the app instead', () async {
      final container = containerWith(
        setting: true,
        access: await lookedAtOutdatedHost(),
      );
      addTearDown(container.dispose);
      final pane = openLocalPane(container);
      addTearDown(pane.dispose);
      expect(pane, isNot(isA<HostTerminalInstance>()));
    });

    test('a pane whose session it holds still goes to it', () async {
      final container = containerWith(
        setting: true,
        access: await lookedAtOutdatedHost(),
      );
      addTearDown(container.dispose);
      final pane = container.read(terminalInstanceFactoryProvider)(
        id: 'kept',
        profile: const TerminalProfile(
          id: 'cmd',
          label: 'Command Prompt',
          shell: TerminalShell.commandPrompt,
        ),
      );
      addTearDown(pane.dispose);
      expect(pane, isA<HostTerminalInstance>());
    });
  });
}
