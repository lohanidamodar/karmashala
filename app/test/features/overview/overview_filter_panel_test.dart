import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/presentation/overview_filters.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala_ui/theme.dart';

import 'mission_fixture.dart';

/// **View and filters**: checklists with counts, Only, All and a summary; a
/// count on the funnel; Reset; what a card shows; a popover under the funnel
/// on a desktop and a sheet on a phone, at 1× and 1.6× text.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-filter-panel');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  group('the checklist', () {
    const options = <OverviewChecklistOption>[
      (id: 'a', label: 'Alpha', count: 4),
      (id: 'b', label: 'Beta', count: 2),
      (id: 'c', label: 'Gamma', count: 1),
      (id: 'd', label: 'Delta', count: 7),
      (id: 'e', label: 'Epsilon', count: 3),
      (id: 'f', label: 'Zeta', count: 5),
    ];

    Future<List<Set<String>?>> pumpList(
      WidgetTester tester, {
      List<OverviewChecklistOption> options = options,
      Set<String>? selected,
    }) async {
      final changes = <Set<String>?>[];
      var current = selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: OverviewChecklist(
                  keyPrefix: 'p',
                  title: 'Projects',
                  noun: 'projects',
                  options: options,
                  selected: current,
                  onChanged: (next) => setState(() {
                    changes.add(next);
                    current = next;
                  }),
                ),
              ),
            ),
          ),
        ),
      );
      return changes;
    }

    String summary(WidgetTester tester) =>
        tester.widget<Text>(byKey('p-summary')).textSpan!.toPlainText().trim();

    testWidgets('a row per choice with its count, and the summary', (
      tester,
    ) async {
      await pumpList(tester);
      expect(summary(tester), 'Projects  Showing all 6 projects');
      for (final option in options) {
        expect(byKey('p:${option.id}'), findsOneWidget);
        expect(
          find.descendant(
            of: byKey('p:${option.id}'),
            matching: find.text('${option.count}'),
          ),
          findsOneWidget,
        );
      }
      // Every one is shown: All has nothing to do.
      expect(tester.widget<TextButton>(byKey('p-all')).onPressed, isNull);
    });

    testWidgets('unticking one shows the rest, and says so', (tester) async {
      final changes = await pumpList(tester);
      await tester.tap(byKey('p:b'));
      await tester.pump();
      expect(changes.single, {'a', 'c', 'd', 'e', 'f'});
      expect(summary(tester), endsWith('Showing 5 of 6 projects'));
      final box = tester.widget<Checkbox>(
        find.descendant(of: byKey('p:b'), matching: find.byType(Checkbox)),
      );
      expect(box.value, isFalse);
    });

    testWidgets('Only keeps that one; All brings every one back', (
      tester,
    ) async {
      final changes = await pumpList(tester);
      await tester.tap(byKey('p-only:d'));
      await tester.pump();
      expect(changes.last, {'d'});
      expect(summary(tester), endsWith('Showing 1 of 6 projects'));

      await tester.tap(byKey('p-all'));
      await tester.pump();
      expect(changes.last, isNull);
      expect(summary(tester), endsWith('Showing all 6 projects'));
    });

    testWidgets('ticking the last one back is "all" again', (tester) async {
      final changes = await pumpList(
        tester,
        selected: {'a', 'b', 'c', 'd', 'e'},
      );
      await tester.tap(byKey('p:f'));
      await tester.pump();
      expect(changes.single, isNull);
    });

    testWidgets('a long list searches; a short one does not', (tester) async {
      await pumpList(tester);
      expect(byKey('p-search'), findsOneWidget);
      await tester.enterText(byKey('p-search'), 'ta');
      await tester.pump();
      // Beta, Delta and Zeta; the rest are out of the list, not unticked.
      expect(byKey('p:b'), findsOneWidget);
      expect(byKey('p:d'), findsOneWidget);
      expect(byKey('p:f'), findsOneWidget);
      expect(byKey('p:a'), findsNothing);
      await tester.enterText(byKey('p-search'), 'xyz');
      await tester.pump();
      expect(find.text('No projects match “xyz”'), findsOneWidget);

      await pumpList(tester, options: options.take(3).toList());
      expect(byKey('p-search'), findsNothing);
    });

    testWidgets('one choice and nothing set: the section hides itself', (
      tester,
    ) async {
      await pumpList(tester, options: options.take(1).toList());
      expect(byKey('ps'), findsNothing);
      expect(find.text('Projects', findRichText: true), findsNothing);
      // Narrowed to it, it stays, so the filter can be undone here.
      await pumpList(tester, options: options.take(1).toList(), selected: {});
      expect(byKey('p:a'), findsOneWidget);
    });
  });

  group('the panel', () {
    Future<dynamic> pump(
      WidgetTester tester, {
      Size size = const Size(1440, 900),
      bool phone = false,
      double textScale = 1,
    }) => pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: size,
      phone: phone,
      textScale: textScale,
    );

    Future<void> open(WidgetTester tester) async {
      await tester.tap(byKey('overview-filter-button'));
      await settleMission(tester);
    }

    testWidgets('on a desktop, a popover under the funnel, its end on it', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);
      expect(byKey('overview-filter-panel'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      final button = tester.getRect(byKey('overview-filter-button'));
      final panel = tester.getRect(
        find
            .ancestor(
              of: byKey('overview-filter-panel'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(panel.top, greaterThanOrEqualTo(button.bottom));
      expect(panel.top - button.bottom, lessThan(16));
      expect((panel.right - button.right).abs(), lessThan(1));
      // Esc closes it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(byKey('overview-filter-panel'), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('on a phone, a bottom sheet', (tester) async {
      await pump(tester, size: const Size(390, 844), phone: true);
      await open(tester);
      expect(byKey('overview-filter-panel'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text(kOverviewFilterTitle), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('View and Filter headings, each control under its own', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);
      double top(Finder f) => tester.getTopLeft(f).dy;
      final view = top(find.text('VIEW'));
      final filter = top(find.text('FILTER'));
      expect(view, lessThan(top(byKey('overview-filter-group'))));
      expect(top(byKey('overview-filter-subs')), lessThan(filter));
      expect(top(byKey('overview-show-on-cards')), lessThan(filter));
      expect(filter, lessThan(top(byKey('overview-filter-projects'))));
      await unmountMission(tester);
    });

    testWidgets('the funnel counts what is set; Reset clears every filter', (
      tester,
    ) async {
      final c = await pump(tester);
      expect(find.byType(Badge), findsNothing);
      c.read(overviewPrefsProvider.notifier)
        ..setMachines({'windows'})
        ..setAgents({AgentIds.claudeCode});
      await settleMission(tester);
      expect(find.byTooltip('Filters (2 set)'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('overview-filter-button'),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );

      await open(tester);
      await tester.tap(byKey('overview-filter-project-only:p-ks'));
      await settleMission(tester);
      expect(c.read(overviewPrefsProvider).filter.projects, {'p-ks'});
      expect(find.byTooltip('Filters (3 set)'), findsOneWidget);

      await tester.tap(byKey('overview-filter-reset'));
      await settleMission(tester);
      final filter = c.read(overviewPrefsProvider).filter;
      expect(filter.projects, isNull);
      expect(filter.machines, isNull);
      expect(filter.agents, isNull);
      expect(c.read(showArchivedSessionsProvider), isFalse);
      expect(find.byTooltip('Filters'), findsOneWidget);
      expect(
        tester.widget<TextButton>(byKey('overview-filter-reset')).onPressed,
        isNull,
      );
      await unmountMission(tester);
    });

    testWidgets('the Show on cards chips hide each part, one tap each', (
      tester,
    ) async {
      final c = await pump(tester);
      await open(tester);
      // No context exists in this workspace: only two toggles.
      expect(byKey('overview-show:context'), findsNothing);
      await tester.tap(byKey('overview-show:machine'));
      await settleMission(tester);
      expect(c.read(overviewPrefsProvider).hiddenDetails, {
        OverviewCardDetail.machine,
      });
      await tester.tap(byKey('overview-show:machine'));
      await tester.tap(byKey('overview-show:project'));
      await settleMission(tester);
      expect(c.read(overviewPrefsProvider).hiddenDetails, {
        OverviewCardDetail.project,
      });
      await unmountMission(tester);
    });

    testWidgets('a part the same on every card says why it is left off', (
      tester,
    ) async {
      final c = await pump(tester);
      c.read(overviewPrefsProvider.notifier).setMachines({'windows'});
      await settleMission(tester);
      await open(tester);
      expect(
        tester.widget<Text>(byKey('overview-show-same')).data,
        'Machine is the same on every card in view, so left off for now.',
      );
      await unmountMission(tester);
    });

    testWidgets('the project checklist sets the board\'s filter', (
      tester,
    ) async {
      final c = await pump(tester);
      await open(tester);
      expect(byKey('overview-filter-project-search'), findsOneWidget);
      await tester.enterText(byKey('overview-filter-project-search'), 'beej');
      await settleMission(tester);
      expect(byKey('overview-filter-project:p-ks'), findsNothing);
      await tester.tap(byKey('overview-filter-project:p-beej'));
      await settleMission(tester);
      expect(
        c.read(overviewPrefsProvider).filter.projects,
        isNot(contains('p-beej')),
      );
      expect(c.read(overviewPrefsProvider).filter.projects, contains('p-ks'));
      await unmountMission(tester);
    });

    for (final (name, size, phone) in [
      ('360', const Size(360, 640), true),
      ('1440', const Size(1440, 900), false),
    ]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('$name px at ${scale}x text: open, scrolled, no overflow', (
          tester,
        ) async {
          final c = await pump(
            tester,
            size: size,
            phone: phone,
            textScale: scale,
          );
          c.read(overviewPrefsProvider.notifier)
            ..setMachines({'windows', 'wsl:arch'})
            ..setProjects({'p-ks', 'p-beej'});
          await settleMission(tester);
          await open(tester);
          await tester.dragUntilVisible(
            byKey('overview-filter-archived'),
            byKey('overview-filter-panel'),
            const Offset(0, -200),
          );
          await settleMission(tester);
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });
      }
    }
  });

  group('the active-filter chips', () {
    testWidgets('stay on one line, the rest folded into +N', (tester) async {
      final c = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        size: const Size(360, 640),
        phone: true,
      );
      c.read(overviewPrefsProvider.notifier)
        ..setMachines({'windows', 'wsl:arch'})
        ..setProjects({'p-ks', 'p-beej', 'p-web'})
        ..setAgents({AgentIds.claudeCode});
      await settleMission(tester);

      final row = tester.getRect(byKey('overview-active-filters'));
      // One chip's height: nothing wrapped onto a second line.
      expect(
        row.height,
        tester.getSize(byKey('overview-active-filter:projects')).height,
      );
      final folds = [
        for (var n = 1; n <= 3; n++)
          if (byKey(
            'overview-active-filter-fold:$n',
          ).hitTestable().evaluate().isNotEmpty)
            n,
      ];
      expect(folds, hasLength(1));
      // What is drawn plus what the fold counts is every filter.
      final drawn = [
        for (final kind in ['projects', 'agents', 'machines'])
          if (byKey(
            'overview-active-filter:$kind',
          ).hitTestable().evaluate().isNotEmpty)
            kind,
      ];
      expect(drawn, isNotEmpty);
      expect(drawn.length + folds.single, 3);
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets('all of them when there is room', (tester) async {
      final c = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
      );
      c.read(overviewPrefsProvider.notifier)
        ..setMachines({'windows'})
        ..setAgents({AgentIds.claudeCode});
      await settleMission(tester);
      expect(
        byKey('overview-active-filter:machines').hitTestable(),
        findsOneWidget,
      );
      expect(
        byKey('overview-active-filter:agents').hitTestable(),
        findsOneWidget,
      );
      for (var n = 1; n <= 2; n++) {
        expect(
          byKey('overview-active-filter-fold:$n').hitTestable(),
          findsNothing,
        );
      }
      await unmountMission(tester);
    });
  });
}
