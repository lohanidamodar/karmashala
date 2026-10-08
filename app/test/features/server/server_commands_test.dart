import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:path/path.dart' as p;
import 'package:karmashala/src/features/server/application/server_commands.dart';
import 'package:karmashala/src/features/server/application/server_overview.dart';
import 'package:karmashala/src/features/server/presentation/server_command_actions.dart';
import 'package:karmashala/src/features/settings/application/settings_tab.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show HostSupervision, HostSupervisionPhase;

import '../../support/fake_data_server.dart';
import '../terminal/fake_instance.dart';

/// The server commands quick open and the tray offer: which apply to the
/// server's state, the line the tray shows, and the shell running a request
/// that came from outside the widget tree with the Settings page's confirm.
void main() {
  // Every command acts through localHostSessionAccessProvider, built by
  // localHostSessionAccessFor: a probe's is its own host, never the owner's.
  group('a probe', () {
    test('acts on the host in its own data folder', () {
      final data = p.join(Directory.systemTemp.path, 'ks-probe-commands');
      final paths = probeHostPaths(
        ProbeMode(enabled: true, dataDirectory: data),
      );
      expect(paths!.directory.path, p.join(p.absolute(data), 'host'));
    });

    test('with no data folder has no server to act on', () {
      expect(localHostSessionAccessFor(ProbeMode.on), isNull);
    });
  });

  ServerOverview overview({
    ServerRunState state = ServerRunState.running,
    int? live = 3,
    bool canStart = false,
    bool canRestart = true,
    bool canStop = true,
    String? refusal,
    bool elsewhere = false,
  }) => ServerOverview(
    state: state,
    appVersion: '1.31.1',
    liveSessions: live,
    endedSessions: 0,
    canStart: canStart,
    canRestart: canRestart,
    canStop: canStop,
    controlsRefusal: refusal,
    usesAnotherMachine: elsewhere,
  );

  group('which commands apply', () {
    test('a running server can be restarted or stopped', () {
      expect(serverCommandsFor(overview()), [
        ServerCommand.restart,
        ServerCommand.stop,
      ]);
    });

    test('a stopped one can only be started', () {
      expect(
        serverCommandsFor(
          overview(
            state: ServerRunState.stopped,
            canStart: true,
            canRestart: false,
            canStop: false,
          ),
        ),
        [ServerCommand.start],
      );
    });

    test('none while this app is not the one running the server', () {
      expect(
        serverCommandsFor(
          overview(refusal: 'Elsewhere.', canStart: true, elsewhere: true),
        ),
        isEmpty,
      );
      expect(serverCommandsFor(null), isEmpty);
    });

    test('labels', () {
      expect(ServerCommand.start.label, 'Start server');
      expect(ServerCommand.restart.label, 'Restart server');
      expect(ServerCommand.stop.label, 'Stop server');
    });
  });

  group('the tray line', () {
    test('names the state and the sessions running', () {
      expect(describeServerLine(overview()), 'Server: running · 3 sessions');
      expect(
        describeServerLine(overview(live: 1)),
        'Server: running · 1 session',
      );
      expect(describeServerLine(overview(live: null)), 'Server: running');
      expect(
        describeServerLine(overview(state: ServerRunState.stopped, live: 0)),
        'Server: stopped',
      );
      expect(
        describeServerLine(overview(state: ServerRunState.starting)),
        'Server: starting…',
      );
    });

    test('says so when the window uses another machine\'s server', () {
      expect(
        describeServerLine(overview(refusal: 'x', elsewhere: true)),
        'Server: on another machine',
      );
    });

    test('says it has not read the server yet', () {
      expect(describeServerLine(null), 'Server: not read yet');
    });
  });

  group('a local overview offers Start', () {
    HostDeployment deployment(HostDeploymentStatus status) => HostDeployment(
      status: status,
      observedAt: DateTime.utc(2026, 10, 6),
      reason: status.name,
    );

    test('when nothing is running', () async {
      final o = await localServerOverview(
        reading: deployment(HostDeploymentStatus.unknown),
        supervision: null,
        listSessions: null,
      );
      expect(o.canStart, isTrue);
    });

    test('when supervision stopped it', () async {
      final o = await localServerOverview(
        reading: deployment(HostDeploymentStatus.unknown),
        supervision: HostSupervision(
          phase: HostSupervisionPhase.stopped,
          observedAt: DateTime.utc(2026, 10, 6),
        ),
        listSessions: null,
      );
      expect(o.canStart, isTrue);
    });

    test('not when it runs, nor before anything was checked', () async {
      final running = await localServerOverview(
        reading: deployment(HostDeploymentStatus.ready),
        supervision: null,
        listSessions: null,
      );
      expect(running.canStart, isFalse);
      final unchecked = await localServerOverview(
        reading: null,
        supervision: null,
        listSessions: null,
      );
      expect(unchecked.canStart, isFalse);
    });
  });

  group('a request from outside the tree', () {
    Future<(ProviderContainer, _FakeHostStatus)> pump(
      WidgetTester tester,
      ServerOverview value,
    ) async {
      final status = _FakeHostStatus();
      final server = FakeDataServer();
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          ...fakeTerminalOverrides(),
          localHostSessionAccessProvider.overrideWithValue(null),
          localHostStatusProvider.overrideWith(() => status),
          serverOverviewProvider.overrideWith((ref) async => value),
        ],
      );
      addTearDown(container.dispose);
      await container.read(serverOverviewProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: _Listener())),
        ),
      );
      return (container, status);
    }

    // The owner (2026-10-08): the tray's Stop and Restart are the person's
    // word already; asking again in the window, which may be hidden, is a
    // second click.
    testWidgets('Stop from the tray stops at once, asking nothing', (
      tester,
    ) async {
      final (container, status) = await pump(tester, overview(live: 2));

      container
          .read(serverCommandRequestProvider.notifier)
          .ask(ServerCommand.stop);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(status.calls, ['stop(force: true)']);
    });

    testWidgets('Restart from the tray restarts at once, asking nothing', (
      tester,
    ) async {
      final (container, status) = await pump(tester, overview(live: 2));

      container
          .read(serverCommandRequestProvider.notifier)
          .ask(ServerCommand.restart);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(status.calls, ['restart(force: true)']);
    });

    testWidgets('an idle server restarts from the tray without force', (
      tester,
    ) async {
      final (container, status) = await pump(tester, overview(live: 0));

      container
          .read(serverCommandRequestProvider.notifier)
          .ask(ServerCommand.restart);
      await tester.pumpAndSettle();
      expect(status.calls, ['restart(force: false)']);
    });

    // Ctrl+K calls runServerCommand with its default, as Settings confirms.
    testWidgets('Restart from Ctrl+K confirms, and Cancel does nothing', (
      tester,
    ) async {
      final (_, status) = await pump(tester, overview(live: 1));

      unawaited(
        runServerCommand(
          tester.element(find.byType(_Listener)),
          ServerCommand.restart,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restart the server?'), findsOneWidget);
      expect(find.textContaining('ends the 1 running session'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(status.calls, isEmpty);
    });

    testWidgets('the same command asked twice is acted on twice', (
      tester,
    ) async {
      final (container, status) = await pump(tester, overview(live: 0));
      final requests = container.read(serverCommandRequestProvider.notifier);

      for (var i = 0; i < 2; i++) {
        requests.ask(ServerCommand.stop);
        await tester.pumpAndSettle();
      }
      expect(status.calls, ['stop(force: false)', 'stop(force: false)']);
    });

    testWidgets('Start asks nothing', (tester) async {
      final (container, status) = await pump(
        tester,
        overview(
          state: ServerRunState.stopped,
          canStart: true,
          canRestart: false,
          canStop: false,
        ),
      );

      container
          .read(serverCommandRequestProvider.notifier)
          .ask(ServerCommand.start);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(status.calls, ['start()']);
    });

    testWidgets('nothing acts on a server this app does not run', (
      tester,
    ) async {
      final (container, status) = await pump(
        tester,
        overview(refusal: 'Elsewhere.', elsewhere: true),
      );

      container
          .read(serverCommandRequestProvider.notifier)
          .ask(ServerCommand.stop);
      await tester.pumpAndSettle();
      expect(find.text('Stop the server?'), findsNothing);
      expect(status.calls, isEmpty);
    });

    testWidgets('Open Server settings lands on its status section', (
      tester,
    ) async {
      final (container, _) = await pump(tester, overview());

      container.read(serverCommandRequestProvider.notifier).openSettings();
      await tester.pumpAndSettle();
      expect(
        container.read(settingsTabSectionProvider)?.anchor,
        SettingsAnchor.serverStatus,
      );
    });
  });
}

class _Listener extends ConsumerWidget {
  const _Listener();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    listenForServerCommandRequests(context, ref);
    return const SizedBox.expand();
  }
}

class _FakeHostStatus extends LocalHostStatusController {
  final calls = <String>[];

  @override
  HostDeployment? build() => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> start() async => calls.add('start()');

  @override
  Future<void> restart({required bool force}) async =>
      calls.add('restart(force: $force)');

  @override
  Future<void> stop({required bool force}) async =>
      calls.add('stop(force: $force)');
}
