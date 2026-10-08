import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/activity_strip.dart';
import 'package:karmashala/src/app/shell/phone_more_page.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/presentation/automation_runs_view.dart';
import 'package:karmashala/src/features/automations/presentation/automations_settings_link.dart';
import 'package:karmashala/src/features/automations/presentation/automations_tab_view.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// Automations have a tab of their own: Automations, Runs and Resumes, with
/// Settings pointing there.
void main() {
  late ProviderContainer container;
  final now = DateTime.utc(2026, 10, 7, 9);

  Automation nightly() => Automation(
    id: 'auto1',
    repositoryId: 'r1',
    name: 'Nightly',
    schedule: const AutomationSchedule.cron('0 2 * * *'),
    agentInstallationId: 'a1',
    prompt: 'fix it',
    permissionMode: null,
    enabled: true,
    armedAt: now,
  );

  setUp(() async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.automationRows.insert(nightly());
    server.automationRows.insertRun(
      AutomationRun(
        id: 'run1',
        automationId: 'auto1',
        scheduledFor: now,
        firedAt: now,
        state: AutomationRunState.failed,
        reason: 'The agent this run started failed.',
        finishedAt: now,
      ),
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester, Widget child, {Size? size}) async {
    if (size != null) {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the tab has the shared header and three lists', (tester) async {
    await pump(tester, const AutomationsTabView());
    expect(find.text('Automations'), findsWidgets);
    expect(find.byKey(const ValueKey('automations-section')), findsOneWidget);
    expect(find.text('Nightly'), findsWidgets);

    await tester.tap(_segment('Runs'));
    await tester.pumpAndSettle();
    expect(find.byType(RunTile), findsOneWidget);
    await tester.tap(find.byType(RunTile));
    await tester.pumpAndSettle();
    expect(find.text('The agent this run started failed.'), findsOneWidget);

    await tester.tap(_segment('Resumes'));
    await tester.pumpAndSettle();
    expect(find.text('When an agent hits its usage limit'), findsOneWidget);
  });

  testWidgets('it fits a phone, a desktop and large text', (tester) async {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final section in AutomationsSection.values) {
        container.read(automationsSectionProvider.notifier).show(section);
        await pump(tester, const AutomationsTabView(), size: size);
        expect(tester.takeException(), isNull, reason: '$size $section');
      }
    }
    container
        .read(automationsSectionProvider.notifier)
        .show(AutomationsSection.runs);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              textScaler: TextScaler.linear(1.6),
            ),
            child: const Scaffold(body: AutomationsTabView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Settings keeps a link to the tab', (tester) async {
    await pump(
      tester,
      const AutomationsSettingsLink(
        anchor: SettingsAnchor.automations,
        section: AutomationsSection.automations,
      ),
    );
    expect(find.text('Open Automations'), findsOneWidget);
    expect(find.text('They have their own tab, Automations.'), findsOneWidget);
  });

  test(
    'searching Settings for automations, webhooks or schedules finds it',
    () {
      for (final query in const ['automation', 'webhook', 'schedule', 'cron']) {
        expect(
          searchSettings(query).map((e) => e.anchor),
          contains(SettingsAnchor.automations),
          reason: query,
        );
      }
      expect(
        searchSettings('usage limit').map((e) => e.anchor),
        contains(SettingsAnchor.automations),
      );
    },
  );

  test('the words a person would search Settings for still find it', () {
    for (final query in const [
      'automation',
      'schedule',
      'cron',
      'nightly',
      'unattended',
      'webhook',
    ]) {
      expect(
        SettingsSectionId.automations.matches(query),
        isTrue,
        reason: '"$query" should find Automations',
      );
    }
  });

  testWidgets('the side rail opens it, and leaves it out when it cannot fit', (
    tester,
  ) async {
    Future<void> rail(double height) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: height,
              child: ActivityStrip(
                selected: null,
                onSelect: (_) {},
                onSettings: () {},
                onUsage: () {},
                onStores: () {},
                onRunning: () {},
                onOverview: () {},
                onAutomations: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await rail(900);
    expect(find.byIcon(AppIcons.lightning), findsOneWidget);
    // Room for every other button, not for one more.
    await rail(470);
    expect(find.byIcon(AppIcons.lightning), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the phone lists it under More', (tester) async {
    await pump(tester, const PhoneMoreList(), size: const Size(390, 844));
    expect(find.text('Automations'), findsOneWidget);
  });
}

Finder _segment(String label) => find.descendant(
  of: find.byKey(const ValueKey('automations-section')),
  matching: find.text(label),
);
