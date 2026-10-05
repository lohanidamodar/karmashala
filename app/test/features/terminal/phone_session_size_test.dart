import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/test_machine.dart';
import '../../terminal/fake_host_access.dart';
import 'fake_instance.dart';

/// A phone opening a session another device is typing into draws it at the
/// session's own size, not its own width: the program keeps drawing for the
/// grid it was given, and redraws aimed at that grid land on the wrong rows
/// of a narrower one. Another device with it open, typing or not, keeps its
/// size until the phone presses Take over.
void main() {
  ClientCapabilities phone() {
    final measured = ClientCapabilities.measure();
    return ClientCapabilities(
      systemIntegration: measured.systemIntegration,
      osToasts: measured.osToasts,
      localNotifications: measured.localNotifications,
      localDevices: measured.localDevices,
      externalApps: measured.externalApps,
      fileDrop: measured.fileDrop,
      relaunch: measured.relaunch,
      density: UiDensity.touch,
      hostsServer: measured.hostsServer,
      multicastLock: measured.multicastLock,
      mediaPlayback: measured.mediaPlayback,
      deviceName: measured.deviceName,
      camera: measured.camera,
    );
  }

  Future<void> frames(WidgetTester tester, int count) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The phone opens the session's terminal; the server then says [told].
  Future<(HostTerminalInstance, ScriptedHostChannel)> open(
    WidgetTester tester,
    PresenceMessage told,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final access = PaneAccess(readyDeployment());
    HostTerminalInstance? pane;
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          machine: TestMachine(),
          instanceFactory:
              ({
                required id,
                required profile,
                workingDirectory,
                restoredScrollback,
                shellIntegration = false,
                agentLaunch,
                adoptTerminal,
              }) {
                final sessionId = 'karmashala_local_$id';
                access.liveSessions.add(sessionId);
                access.grids[sessionId] = (200, 50);
                return pane = HostTerminalInstance(
                  id: id,
                  title: 'claude',
                  profileId: profile.id,
                  access: access,
                  sessionId: sessionId,
                  drawsAtSessionGrid: true,
                );
              },
        ),
        clientCapabilitiesProvider.overrideWithValue(phone()),
      ],
    );
    addTearDown(container.dispose);
    openFirstTerminal(container);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: UiDensityScope(
            density: UiDensity.touch,
            child: Scaffold(body: WorkbenchView()),
          ),
        ),
      ),
    );
    await frames(tester, 10);
    final channel = access.channels.single..push(told);
    await frames(tester, 20);
    return (pane!, channel);
  }

  /// The fake answers no claim; its request is let time out.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  }

  PresenceMessage presence({String? holder, required List<String> viewers}) =>
      PresenceMessage(
        sessionRef: 1,
        holder: holder,
        viewers: viewers,
        sizedFor: 'desktop-pc',
        columns: 200,
        rows: 50,
      );

  testWidgets('at 390×844, a 200-column screen another device holds', (
    tester,
  ) async {
    final (pane, channel) = await open(
      tester,
      presence(holder: 'desktop-pc', viewers: ['karmashala']),
    );

    expect(find.text('Typing: desktop-pc'), findsOneWidget);
    expect(find.text('Desktop size'), findsOneWidget);
    expect(find.text('Fitted'), findsNothing);
    expect(pane.drawsAtSessionGrid, isTrue);
    expect((pane.terminal.viewWidth, pane.terminal.viewHeight), (200, 50));
    expect(channel.all<ClaimMessage>(), isEmpty, reason: 'looking only');

    await tester.tap(find.byKey(const Key('terminal-take-over')));
    await frames(tester, 20);
    expect(find.text('Fitted'), findsOneWidget);
    expect(pane.terminal.viewWidth, lessThan(200));
    expect(channel.all<ClaimMessage>().single.takeOver, isTrue);

    await close(tester);
  });

  for (final (who, told) in [
    ('nobody types in it', presence(viewers: ['karmashala', 'desktop-pc'])),
    (
      'this phone typed in it last',
      presence(holder: 'karmashala', viewers: ['desktop-pc']),
    ),
  ]) {
    testWidgets('opened while the desktop has it open and $who, it is not '
        'resized for the phone', (tester) async {
      final (pane, channel) = await open(tester, told);

      expect(pane.drawsAtSessionGrid, isTrue);
      expect((pane.terminal.viewWidth, pane.terminal.viewHeight), (200, 50));
      expect(channel.all<ClaimMessage>(), isEmpty);
      expect(
        channel.all<ResizeMessage>().where((r) => r.columns != 200),
        isEmpty,
      );

      await close(tester);
    });
  }

  testWidgets('opened with no other device on it, it is fitted to the '
      'phone', (tester) async {
    final (pane, channel) = await open(
      tester,
      presence(viewers: ['karmashala']),
    );

    expect(pane.drawsAtSessionGrid, isFalse);
    expect(channel.all<ClaimMessage>().single.takeOver, isTrue);

    await close(tester);
  });
}
