import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/activity_strip.dart';
import 'package:karmashala/src/app/shell/phone_more_page.dart';
import 'package:karmashala/src/app/widgets/dashboard_glance.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/presentation/automations_settings_link.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/overview/glances/dashboard_glances.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_editor.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_dialog.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/workflows/presentation/pipelines_grid_view.dart';
import 'package:karmashala/src/features/workflows/presentation/workflow_runs_view.dart';
import 'package:karmashala/src/features/workflows/presentation/workflows_glance.dart';
import 'package:karmashala/src/features/workflows/presentation/workflows_tab_view.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_ui/icons.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// Automations and pipelines share one page, **Workflows**: Automations,
/// Pipelines, Runs and Resumes, its pipelines edited in the page, a glance on
/// the dashboard, and the old ways in landing on it.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 10, 9);

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

  final mine = kPipelineTemplates.first.copyWith(
    id: 'p-mine',
    name: 'Ship a fix',
    builtIn: false,
  );

  PipelineRun pipelineRun(
    String id, {
    PipelineRunState state = PipelineRunState.finished,
    Duration ago = Duration.zero,
  }) => PipelineRun(
    id: id,
    definition: mine,
    repositoryId: 'r1',
    input: 'do it',
    state: state,
    byPerson: true,
    createdAt: now.subtract(ago),
    updatedAt: now.subtract(ago),
    finishedAt: state.isActive ? null : now.subtract(ago),
  );

  setUp(() async {
    server = FakeDataServer();
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
    server.pipelineRows.saved[mine.id] = mine;
    server.pipelineRows
      ..putRun(pipelineRun('pr1', ago: const Duration(hours: 1)))
      ..putRun(
        pipelineRun(
          'pr2',
          state: PipelineRunState.failed,
          ago: const Duration(hours: 2),
        ),
      )
      ..putRun(
        pipelineRun(
          'pr3',
          state: PipelineRunState.waiting,
          ago: const Duration(minutes: 5),
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

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder segment(WorkflowsSection section) =>
      find.byKey(ValueKey('workflows-section:${section.name}'));

  void show(WorkflowsSection section) =>
      container.read(workflowsSectionProvider.notifier).show(section);

  group('the rename', () {
    testWidgets('the page is Workflows, with its own glyph', (tester) async {
      await pump(tester, const WorkflowsTabView());
      expect(find.text('Workflows'), findsOneWidget);
      expect(find.byIcon(AppIcons.flowArrow), findsWidgets);
      // The things themselves keep their name.
      expect(find.byTooltip('New automation'), findsOneWidget);
    });

    test('a layout saved when it was Automations opens Workflows', () {
      // The tab keeps the pane id it always had, so a saved layout or an old
      // link to it lands on the renamed page.
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = terminals.openWorkflowsTab();
      expect(isAutomationsPane(kAutomationsPaneId), isTrue);
      expect(terminals.titleForPane(kAutomationsPaneId), 'Workflows');
      expect(terminals.titleForTab(tabId), 'Workflows');
    });

    testWidgets('the side rail opens it, and leaves it out when it cannot '
        'fit', (tester) async {
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
      expect(find.byIcon(AppIcons.flowArrow), findsOneWidget);
      // Room for every other button, not for one more.
      await rail(470);
      expect(find.byIcon(AppIcons.flowArrow), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the phone lists it under More', (tester) async {
      await pump(tester, const PhoneMoreList(), size: const Size(390, 844));
      expect(find.text('Workflows'), findsOneWidget);
      expect(find.text('Automations'), findsNothing);
    });

    testWidgets('Settings links to it by its new name', (tester) async {
      await pump(
        tester,
        const AutomationsSettingsLink(
          anchor: SettingsAnchor.automations,
          section: WorkflowsSection.automations,
        ),
      );
      expect(find.text('Open Workflows'), findsOneWidget);
      expect(find.text('They have their own page, Workflows.'), findsOneWidget);
    });

    test('searching Settings for automations, webhooks or schedules still '
        'finds it', () {
      for (final query in const ['automation', 'webhook', 'schedule', 'cron']) {
        expect(
          searchSettings(query).map((e) => e.anchor),
          contains(SettingsAnchor.automations),
          reason: query,
        );
      }
    });
  });

  group('the sections', () {
    testWidgets('Automations — resumes under them — Pipelines and Runs', (
      tester,
    ) async {
      await pump(tester, const WorkflowsTabView());
      expect(WorkflowsSection.values, hasLength(3));
      expect(find.byKey(const ValueKey('automations-list')), findsOneWidget);
      expect(find.text('Nightly'), findsWidgets);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('workflows-resumes')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('When an agent hits its usage limit'), findsOneWidget);

      await tester.tap(segment(WorkflowsSection.pipelines));
      await tester.pumpAndSettle();
      expect(find.byType(PipelinesGridView), findsOneWidget);
      expect(find.byTooltip('New pipeline'), findsOneWidget);

      await tester.tap(segment(WorkflowsSection.runs));
      await tester.pumpAndSettle();
      expect(find.byType(WorkflowRunsView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('workflow-runs-filter')),
        findsOneWidget,
      );
    });

    for (final (size, scale) in const [
      (Size(360, 740), 1.0),
      (Size(360, 740), 1.6),
      (Size(412, 915), 1.0),
      (Size(412, 915), 1.6),
      (Size(1440, 900), 1.0),
      (Size(1440, 900), 1.6),
    ]) {
      testWidgets('every section fits ${size.width.toInt()} px at $scale', (
        tester,
      ) async {
        for (final section in WorkflowsSection.values) {
          show(section);
          await pump(
            tester,
            const WorkflowsTabView(),
            size: size,
            textScale: scale,
          );
          expect(tester.takeException(), isNull, reason: '$section');
        }
        // A run's detail, and the pipeline editor, in the page.
        container
            .read(selectedWorkflowRunProvider.notifier)
            .select(const WorkflowRunRef(WorkflowRunKind.pipeline, 'pr3'));
        show(WorkflowsSection.runs);
        await pump(
          tester,
          const WorkflowsTabView(),
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull, reason: 'run detail');
        container.read(pipelineEditingProvider.notifier).open(mine);
        show(WorkflowsSection.pipelines);
        await pump(
          tester,
          const WorkflowsTabView(),
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull, reason: 'editor');
      });
    }
  });

  group('the pipelines grid', () {
    testWidgets('saved ones and templates, grouped, each with its flow, last '
        'run and success rate', (tester) async {
      show(WorkflowsSection.pipelines);
      await pump(tester, const WorkflowsTabView());
      expect(find.text('YOUR PIPELINES · 1'), findsOneWidget);
      expect(
        find.text('BUILT-IN TEMPLATES · ${kPipelineTemplates.length}'),
        findsOneWidget,
      );
      for (final p in [mine, ...kPipelineTemplates]) {
        expect(find.byKey(ValueKey('pipeline-tile:${p.id}')), findsOneWidget);
        expect(find.byKey(ValueKey('pipeline-flow:${p.id}')), findsOneWidget);
      }
      String textOf(String key) =>
          tester.widget<Text>(find.byKey(ValueKey(key))).data!;
      // Its newest run waits at a gate; of the two that ended, one finished.
      expect(textOf('pipeline-last:p-mine'), startsWith('Waiting for you at'));
      expect(textOf('pipeline-rate:p-mine'), '50% finished · last 2 ended');
      final template = kPipelineTemplates.first.id;
      expect(textOf('pipeline-last:$template'), 'Never run');
      expect(textOf('pipeline-rate:$template'), 'No finished runs yet');
    });

    testWidgets('Run opens the run dialog on that pipeline', (tester) async {
      show(WorkflowsSection.pipelines);
      await pump(tester, const WorkflowsTabView());
      await tester.tap(find.byKey(const ValueKey('pipeline-run:p-mine')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RunPipelineDialog>(find.byType(RunPipelineDialog))
            .pipelineId,
        'p-mine',
      );
    });

    testWidgets('Edit and New open the editor in the page, beside the grid on '
        'a desktop', (tester) async {
      show(WorkflowsSection.pipelines);
      await pump(tester, const WorkflowsTabView());
      await tester.tap(find.byKey(const ValueKey('pipeline-edit:p-mine')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('pipeline-editor-page')),
        findsOneWidget,
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('pipelines-grid')), findsOneWidget);
      final name = find.byKey(const ValueKey('pipeline-editor-name'));
      expect(tester.widget<TextField>(name).controller!.text, 'Ship a fix');
      await tester.enterText(name, 'Ship it');
      await tester.tap(find.byKey(const ValueKey('pipeline-editor-save')));
      await tester.pumpAndSettle();
      expect(server.pipelineRows.saved['p-mine']!.name, 'Ship it');
      expect(find.byKey(const ValueKey('pipeline-editor-page')), findsNothing);

      await tester.tap(find.byTooltip('New pipeline'));
      await tester.pumpAndSettle();
      expect(find.byType(PipelineEditor), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pipeline-editor-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(PipelineEditor), findsNothing);
    });

    testWidgets('on a phone the editor is the whole page', (tester) async {
      show(WorkflowsSection.pipelines);
      await pump(tester, const WorkflowsTabView(), size: const Size(390, 844));
      await tester.tap(find.byTooltip('New pipeline'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('pipeline-editor-page')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('pipelines-grid')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Duplicate edits a copy; Delete is offered for saved ones '
        'only', (tester) async {
      show(WorkflowsSection.pipelines);
      await pump(tester, const WorkflowsTabView());
      final template = kPipelineTemplates.first;
      await tester.tap(find.byKey(ValueKey('pipeline-menu:${template.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Delete…'), findsNothing);
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      final editing = container.read(pipelineEditingProvider)!;
      expect(editing.draft.id, isEmpty);
      expect(editing.draft.name, '${template.name} (copy)');
      expect(editing.draft.builtIn, isFalse);
      container.read(pipelineEditingProvider.notifier).close();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('pipeline-menu:p-mine')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(server.pipelineRows.saved, isEmpty);
      expect(find.byKey(const ValueKey('pipeline-tile:p-mine')), findsNothing);
    });
  });

  group('the glance', () {
    test('it is in the dashboard\'s registry, once', () {
      final glances = container.read(dashboardGlancesProvider);
      expect(glances.where((g) => g.id == 'workflows'), hasLength(1));
      expect(workflowsGlance.title, 'Workflows');
    });

    testWidgets('today\'s runs, waiting on you, failed, and the newest', (
      tester,
    ) async {
      await pump(
        tester,
        const WorkflowsGlanceBody(),
        size: const Size(320, 200),
      );
      expect(
        find.text('4 runs today · 1 waiting on you · 2 failed'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workflows-glance-newest')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nightly', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('one line on a phone\'s strip, at large text', (tester) async {
      await pump(
        tester,
        const GlanceScope(compact: true, child: WorkflowsGlanceBody()),
        size: const Size(240, 80),
        textScale: 1.6,
      );
      expect(
        find.byKey(const ValueKey('workflows-glance-newest')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  test('a pipeline inbox item opens its run in Workflows → Runs', () async {
    container.listen(attentionInboxProvider, (_, _) {});
    final opened = <String>[];
    container.listen(
      workflowsOpenRequestProvider,
      (_, request) => opened.add(request!.runId),
    );
    server.attention.openWanted(pipelineInboxOpenId('pr3'));
    await pumpEventQueue();
    expect(opened, ['pr3']);
  });
}
