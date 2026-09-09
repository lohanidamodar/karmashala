import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_presets.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/terminal_preset_dao.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_preset.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open_item.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// A preset is **the shape and nothing running in it.**
///
/// The app already brings panes back across a restart, so a preset that carried
/// live sessions would be a second, worse copy of that. What it carries is the
/// declaration — which regions, split which way, each holding a profile and a
/// directory — so opening one starts fresh terminals rather than resurrecting
/// old ones, and a preset can be opened twice.
///
/// The eager/lazy half is the reason the backlog wanted it at all: *"a preset
/// that launches nine processes is worse than no preset; one that declares nine
/// and starts four is the useful thing."* So the tab that ends up in front
/// starts, and every other tab waits until somebody looks at it.
void main() {
  ProviderContainer harness({AppDatabase? database}) {
    final container = fakeTerminalContainer(database: database);
    addTearDown(container.dispose);
    return container;
  }

  TerminalSessionsController controllerOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  group('capturing', () {
    test('a preset is exactly the shape, and nothing that is running', () {
      final container = harness();
      final controller = controllerOf(container);
      controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws\one',
      );
      final right = controller.splitPaneWith(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
        workingDirectory: r'C:\ws\two',
      )!;
      controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws\three',
      );
      // Output the preset must not carry: a shape is not a session.
      (controller.instanceFor(right)! as FakeTerminalInstance).receive(
        'a command somebody ran',
      );

      final preset = controller.capturePreset(id: 'p1', name: 'Two and one');

      expect(preset.tabs, hasLength(2));
      expect(preset.paneCount, 3);
      expect(
        preset.tabs.first.layout.groups,
        hasLength(2),
        reason: 'the split is part of the shape',
      );
      expect(
        preset.tabs.first.panes.map((pane) => pane.profileId),
        [TerminalProfile.powerShellId, TerminalProfile.commandPromptId],
      );
      expect(preset.tabs.first.panes.map((pane) => pane.workingDirectory), [
        r'C:\ws\one',
        r'C:\ws\two',
      ]);
      expect(
        preset.activeTab,
        1,
        reason: 'the tab that was in front is the one that will be',
      );
      // The shape is a document, and the whole of it survives a round trip.
      final json = preset.toJson();
      final again = TerminalPreset.fromJson(
        id: preset.id,
        name: preset.name,
        shape: json,
      )!;
      expect(again.paneCount, 3);
      expect(again.tabs.first.layout.toJson(), preset.tabs.first.layout.toJson());
      expect(
        '$json',
        isNot(contains('a command somebody ran')),
        reason: 'no scrollback, no liveness, nothing that was running',
      );
    });

    test('an empty region declares nothing', () {
      final container = harness();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      controller.splitPane(SplitAxis.horizontal);

      final preset = controller.capturePreset(id: 'p1', name: 'One');

      expect(preset.tabs.single.panes, hasLength(1));
      expect(preset.tabs.single.layout.panes, hasLength(1));
    });
  });

  group('opening', () {
    test('the panes come back with the right profiles and directories', () {
      final container = harness();
      final controller = controllerOf(container);
      controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws\one',
      );
      controller.splitPaneWith(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
        workingDirectory: r'C:\ws\two',
      );
      final preset = controller.capturePreset(id: 'p1', name: 'Pair');
      final before = {
        for (final tab in container.read(terminalSessionsControllerProvider).tabs)
          ...tab.layout.panes,
      };

      final opening = controller.openPreset(preset);

      expect(opening.openedTabs, 1);
      expect(opening.openedPanes, 2);
      expect(opening.skippedProfileIds, isEmpty);
      final tabs = container.read(terminalSessionsControllerProvider).tabs;
      expect(tabs, hasLength(2), reason: 'the preset opened beside the tab');
      final opened = tabs.last;
      expect(
        opened.layout.panes.any(before.contains),
        isFalse,
        reason: 'fresh panes — a preset can be opened twice',
      );
      expect(
        [
          for (final id in opened.layout.panes)
            controller.instanceFor(id)!.profileId,
        ],
        [TerminalProfile.powerShellId, TerminalProfile.commandPromptId],
      );
      expect(
        [
          for (final id in opened.layout.panes)
            controller.instanceFor(id)!.workingDirectory,
        ],
        [r'C:\ws\one', r'C:\ws\two'],
      );
      expect(
        opened.layout.groups,
        hasLength(2),
        reason: 'and split the way the preset was',
      );
    });

    test('a tab nobody is looking at declares its panes and starts none', () {
      final container = harness();
      final controller = controllerOf(container);
      // Two tabs, the second in front — so the first is the background one.
      controller.openTab(TerminalProfile.powerShell);
      controller.openTab(TerminalProfile.commandPrompt);
      final preset = controller.capturePreset(id: 'p1', name: 'Two tabs');

      controller.openPreset(preset);

      final tabs = container.read(terminalSessionsControllerProvider).tabs;
      final background = tabs[2];
      final front = tabs[3];
      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        front.id,
        reason: 'the tab that was in front when it was saved is in front now',
      );
      expect(
        controller.instanceFor(background.layout.panes.single),
        isA<DormantTerminalInstance>(),
        reason: 'declared, with no process behind it',
      );
      expect(
        controller.instanceFor(front.layout.panes.single),
        isNot(isA<DormantTerminalInstance>()),
        reason: 'and the one on screen is running',
      );

      // Looking at it is what starts it — the same rule a restored tab follows.
      controller.activateTab(background.id);
      final started = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .firstWhere((tab) => tab.id == background.id);
      expect(
        controller.instanceFor(started.layout.panes.single),
        isNot(isA<DormantTerminalInstance>()),
      );
    });

    test('a profile this machine no longer has is named, not silently '
        'dropped', () {
      final container = harness();
      final controller = controllerOf(container);
      // Hand-built rather than captured: the point is a preset written on a
      // machine that had a WSL distribution this one does not.
      final preset = TerminalPreset(
        id: 'p1',
        name: 'Windows and Ubuntu',
        tabs: [
          PresetTab(
            layout: PaneLayout.single('a')
                .split('a', SplitAxis.horizontal, 'b', 's1'),
            focusedPaneId: 'a',
            panes: const [
              PresetPane(id: 'a', profileId: TerminalProfile.powerShellId),
              PresetPane(id: 'b', profileId: 'wsl:Ubuntu'),
            ],
          ),
        ],
      );

      final opening = controller.openPreset(preset);

      expect(opening.openedTabs, 1);
      expect(opening.openedPanes, 1, reason: 'the others still opened');
      expect(opening.skippedProfileIds, ['wsl:Ubuntu']);
      final opened = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .single;
      expect(opened.layout.panes, hasLength(1));
      expect(
        controller.instanceFor(opened.layout.panes.single)!.profileId,
        TerminalProfile.powerShellId,
      );
      expect(
        presetOpenedMessage(preset, opening),
        allOf(
          contains('Windows and Ubuntu'),
          contains('wsl:Ubuntu'),
          isNot(contains('1')),
        ),
        reason: 'it names what it skipped; a count says nothing to act on',
      );
    });

    test('a preset whose every profile has gone opens nothing and says so', () {
      final container = harness();
      final controller = controllerOf(container);
      const preset = TerminalPreset(
        id: 'p1',
        name: 'All gone',
        tabs: [],
      );
      final gone = TerminalPreset(
        id: preset.id,
        name: preset.name,
        tabs: [
          PresetTab(
            layout: PaneLayout.single('a'),
            focusedPaneId: 'a',
            panes: const [PresetPane(id: 'a', profileId: 'wsl:Ubuntu')],
          ),
        ],
      );

      final opening = controller.openPreset(gone);

      expect(opening.openedTabs, 0);
      expect(opening.openedPanes, 0);
      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        isEmpty,
        reason: 'no empty tab left behind',
      );
      expect(
        presetOpenedMessage(gone, opening),
        contains('Nothing in "All gone" could be opened'),
      );
    });
  });

  group('the store', () {
    test('a preset survives the round trip, and a second save replaces it', () {
      final database = AppDatabase.memory();
      addTearDown(database.close);
      final container = harness(database: database);
      final controller = controllerOf(container);
      controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws',
      );

      final saved = container.read(terminalPresetsProvider).save('  Daily  ');
      expect(saved, isNotNull);
      expect(saved!.name, 'Daily', reason: 'the name is trimmed');

      final read = TerminalPresetDao(database).getAll();
      expect(read, hasLength(1));
      expect(read.single.name, 'Daily');
      expect(read.single.paneCount, 1);
      expect(
        read.single.tabs.single.panes.single.workingDirectory,
        r'C:\ws',
      );

      // A second pane, saved under the same name: one preset, corrected.
      controller.splitPaneWith(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      );
      final again = container.read(terminalPresetsProvider).save('Daily')!;
      final after = TerminalPresetDao(database).getAll();
      expect(after, hasLength(1), reason: 'replaced, not duplicated');
      expect(again.id, saved.id, reason: 'and it kept its id');
      expect(after.single.paneCount, 2);
    });

    test('a row this code cannot parse is skipped, not thrown on', () {
      final database = AppDatabase.memory();
      addTearDown(database.close);
      final dao = TerminalPresetDao(database);
      final now = DateTime.utc(2026, 9, 9);
      dao.save(
        TerminalPreset(
          id: 'good',
          name: 'Good',
          tabs: [
            PresetTab(
              layout: PaneLayout.single('a'),
              focusedPaneId: 'a',
              panes: const [
                PresetPane(id: 'a', profileId: TerminalProfile.powerShellId),
              ],
            ),
          ],
        ),
        now,
      );
      database.execute(
        'INSERT INTO terminal_presets (id, name, shape, created_at, updated_at) '
        "VALUES ('bad', 'Bad', 'not json at all', ?, ?);",
        [now.toIso8601String(), now.toIso8601String()],
      );

      expect(dao.getAll().map((preset) => preset.name), ['Good']);
    });

    test('nothing to capture saves nothing', () {
      final database = AppDatabase.memory();
      addTearDown(database.close);
      final container = harness(database: database);
      expect(container.read(terminalPresetsProvider).save('Empty'), isNull);
      expect(TerminalPresetDao(database).getAll(), isEmpty);
    });
  });

  group('reaching one', () {
    test('presets have a sigil of their own, and it is theirs alone', () {
      expect(QuickOpenGroup.presets.sigil, '~');
      expect(QuickOpenQuery.parse('~daily').only, QuickOpenGroup.presets);
      expect(
        QuickOpenQuery.parse('~daily').text,
        'daily',
        reason: 'the sigil is peeled off, not searched for',
      );
      for (final group in QuickOpenGroup.values) {
        if (group == QuickOpenGroup.presets) continue;
        expect(
          group.sigil,
          isNot('~'),
          reason: 'a sigil two groups answer to belongs to neither',
        );
      }
    });

    testWidgets('the tab strip menu offers to save the layout', (tester) async {
      var saved = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 220,
                child: TerminalTabChip(
                  title: 'zsh',
                  liveness: PaneLiveness.live,
                  selected: true,
                  index: 0,
                  tabCount: 1,
                  onTap: () {},
                  onClose: () {},
                  onEnd: () {},
                  onBulkClose: (_) {},
                  onSavePreset: () => saved++,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('zsh'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Save this layout as a preset…'), findsOneWidget);

      await tester.tap(find.text('Save this layout as a preset…'));
      await tester.pumpAndSettle();
      expect(saved, 1);
    });

    testWidgets('a chip with no workspace behind it does not offer it', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 220,
                child: TerminalTabChip(
                  title: 'zsh',
                  liveness: PaneLiveness.live,
                  selected: true,
                  index: 0,
                  tabCount: 1,
                  onTap: () {},
                  onClose: () {},
                  onEnd: () {},
                  onBulkClose: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('zsh'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Close tab'), findsOneWidget);
      expect(find.text('Save this layout as a preset…'), findsNothing);
    });
  });
}
