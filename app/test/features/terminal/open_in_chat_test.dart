import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/general_pages.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/desktop_client.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import 'fake_instance.dart';

/// Settings › General › "Open agent sessions in chat view": a terminal agent
/// session rests on its chat, a phone's answer unless the person says.
void main() {
  late TestMachine db;
  late ProviderContainer container;

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  String focusedPane() => container
      .read(terminalSessionsControllerProvider)
      .activeTab!
      .focusedPaneId;

  Future<void> prepare({bool chat = true}) async {
    db = TestMachine();
    final server = FakeDataServer(clock: () => testTime).runsOn(db)
      ..environmentRows.upsert(windowsEnv())
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          machine: db,
          data: await server.override(),
          openSessionsInChat: chat,
        ),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
  }

  /// A shell tab, and its group.
  String openShell() {
    terminals().openTab(TerminalProfile.powerShell);
    return terminals().groupOfPane(focusedPane())!;
  }

  /// A tab whose pane runs agent session [id], and its group.
  String openSession(String id) {
    final group = openShell();
    db.server.sessionRows
      ..insert(session(id: id))
      ..updatePaneId(id, focusedPane());
    return group;
  }

  bool onTerminal(String group) =>
      container.read(terminalVisibleInGroupProvider(group));

  group('the default', () {
    Future<bool> answer(UiDensity density, {bool? chosen}) async {
      final server = FakeDataServer(clock: () => testTime);
      final probe = ProviderContainer(
        overrides: [
          await server.override(),
          clientCapabilitiesProvider.overrideWithValue(
            desktopClient(density: density),
          ),
        ],
      );
      addTearDown(probe.dispose);
      if (chosen != null) {
        probe
            .read(settingsControllerProvider.notifier)
            .setOpenSessionsInChat(chosen);
      }
      return probe.read(sessionsOpenInChatProvider);
    }

    testWidgets('is on for a phone and off for a desktop', (tester) async {
      expect(await answer(UiDensity.touch), isTrue, reason: 'a phone');
      expect(await answer(UiDensity.pointer), isFalse, reason: 'a desktop');
    });

    testWidgets('gives way to what the person chose', (tester) async {
      expect(await answer(UiDensity.touch, chosen: false), isFalse);
      expect(await answer(UiDensity.pointer, chosen: true), isTrue);
    });
  });

  testWidgets('on, a terminal agent session rests on its chat', (tester) async {
    await prepare();
    final group = openSession('s1');

    expect(onTerminal(group), isFalse);
    expect(
      container.read(anyChatVisibleProvider),
      isTrue,
      reason: 'the transcript cost gate sees the chat that is up',
    );
  });

  testWidgets('off, the same session rests on its terminal', (tester) async {
    await prepare(chat: false);
    final group = openSession('s1');

    expect(onTerminal(group), isTrue);
    expect(container.read(anyChatVisibleProvider), isFalse);
  });

  testWidgets('a plain shell stays a terminal', (tester) async {
    await prepare();
    final group = openShell();

    expect(onTerminal(group), isTrue);
    expect(container.read(anyChatVisibleProvider), isFalse);
  });

  testWidgets('a hand on the toggle wins for its group', (tester) async {
    await prepare();
    final group = openSession('s1');

    terminals().toggleFaceHere();
    expect(onTerminal(group), isTrue, reason: 'toggled off the chat');
    terminals().showTerminalForPane(focusedPane());
    expect(onTerminal(group), isTrue);
    expect(container.read(anyChatVisibleProvider), isFalse);

    terminals().toggleFaceHere();
    expect(onTerminal(group), isFalse, reason: 'and back');
  });

  testWidgets('opening the session again starts it on its chat', (
    tester,
  ) async {
    await prepare();
    final group = openSession('s1');
    terminals().showFaceIn(group, terminal: true);

    // What a launch, a resume and the Explorer's open all call.
    terminals().revealPane(focusedPane());

    expect(onTerminal(group), isFalse);
  });

  testWidgets('a tab picked from the strip opens on the face it rests on', (
    tester,
  ) async {
    await prepare();
    final group = openSession('s1');
    final sessionTab = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .id;
    terminals().openTab(TerminalProfile.powerShell);
    final shellTab = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .id;
    terminals().revealTab(shellTab);
    expect(onTerminal(group), isTrue, reason: 'the shell beside it');

    terminals()
      ..activateTab(sessionTab)
      ..revealTab(sessionTab);
    expect(onTerminal(group), isFalse);
  });

  testWidgets('the Settings row writes the choice', (tester) async {
    final server = FakeDataServer(clock: () => testTime);
    final probe = ProviderContainer(
      overrides: [
        await server.override(),
        clientCapabilitiesProvider.overrideWithValue(
          desktopClient(density: UiDensity.touch),
        ),
      ],
    );
    addTearDown(probe.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: probe,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SessionViewSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.text('Open agent sessions in chat view');
    expect(row, findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(probe.read(settingsControllerProvider).openSessionsInChat, isNull);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(probe.read(settingsControllerProvider).openSessionsInChat, isFalse);
    expect(probe.read(sessionsOpenInChatProvider), isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });
}
