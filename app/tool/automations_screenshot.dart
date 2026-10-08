// Renders the Automations tab — the list, the editor, Runs — over a fixture
// into PNGs, dark and light, desktop and phone. Lives under tool/ so
// `flutter test` never picks it up:
//
//   flutter test tool/automations_screenshot.dart
//
// Images land in build/automations-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_editor_state.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_templates.dart';
import 'package:karmashala/src/features/automations/presentation/automations_tab_view.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../test/features/terminal/fake_instance.dart';
import '../test/support/fake_data_server.dart';
import '../test/support/fakes.dart';
import '../test/support/fixtures.dart';

const _outDir = 'build/automations-screenshots';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final asset in assets) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }

  await load(kBundledSansFamily, [
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'packages/karmashala_ui/fonts/Geist-$weight.ttf',
  ]);
  await load(kBundledMonoFamily, [
    'packages/karmashala_ui/fonts/JetBrainsMono-Regular.ttf',
  ]);
  await load('packages/picons/PhosphorRegular', [
    'packages/picons/lib/fonts/Phosphor.ttf',
  ]);
  await load('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']);
  await load('packages/picons/PhosphorFill', [
    'packages/picons/lib/fonts/Phosphor-Fill.ttf',
  ]);
}

final _now = DateTime.utc(2026, 10, 7, 9);

Automation _nightly() => Automation(
  id: 'nightly',
  repositoryId: 'r1',
  name: 'Nightly tests and fixes',
  schedule: const AutomationSchedule.cron('0 2 * * *'),
  agentInstallationId: 'a1',
  prompt:
      'Pull the latest, run the tests, and fix anything that broke. Keep the '
      'changes small.',
  permissionMode: const PermissionSelection({'mode': 'auto'}),
  enabled: true,
  armedAt: _now,
  worktree: true,
  steps: kAutomationTemplates.first.build('r1').steps,
);

Automation _review() => Automation(
  id: 'review',
  repositoryId: 'r1',
  name: 'A second agent reviews the work',
  schedule: AutomationSchedule.once(_now),
  agentInstallationId: 'a1',
  prompt: 'Review the latest changes without editing anything.',
  permissionMode: const PermissionSelection({'mode': 'plan'}),
  enabled: true,
  armedAt: _now,
  trigger: const AutomationEventTrigger(
    kind: AutomationEventKind.turnFinished,
    action: AutomationEventAction.startSession,
  ),
  steps: AutomationSteps(const [
    AutomationStep(
      kind: AutomationStepKind.notify,
      when: AutomationStepWhen.always,
    ),
  ]),
);

Automation _triage() => Automation(
  id: 'triage',
  repositoryId: 'r1',
  name: 'Triage new GitHub issues',
  schedule: AutomationSchedule.once(_now),
  agentInstallationId: 'a1',
  prompt: 'Triage {{issue.title}} from {{sender.login}}',
  permissionMode: const PermissionSelection({'mode': 'plan'}),
  enabled: false,
  armedAt: _now,
  webhook: const AutomationWebhook(hookId: '0123456789abcdef0123456789abcdef'),
);

AutomationRun _run(
  String id,
  String automationId,
  AutomationRunState state,
  Duration ago, {
  AutomationRunCause? by,
  List<AutomationStepResult> steps = const [],
}) => AutomationRun(
  id: id,
  automationId: automationId,
  scheduledFor: _now.subtract(ago),
  firedAt: _now.subtract(ago),
  state: state,
  reason: switch (state) {
    AutomationRunState.running => 'Started with Run now.',
    AutomationRunState.failed => 'The agent this run started failed.',
    _ => 'The agent this run started finished.',
  },
  sessionId: 'session-$id',
  baseCheckpointId: 'cp-$id',
  finishedAt: state.isLive
      ? null
      : _now.subtract(ago).add(const Duration(minutes: 21, seconds: 4)),
  checksObservedAt: state.isLive ? null : _now,
  startedBy: by,
  stepResults: steps,
);

Future<ProviderContainer> _container() async {
  final server = FakeDataServer();
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project(name: 'karmashala'));
  server.repositoryRows.insert(repository(name: 'karmashala'));
  server.installationRows.insert(
    agentInstallation(agentId: AgentIds.claudeCode),
  );
  server.automationRows
    ..insert(_nightly())
    ..insert(_review())
    ..insert(_triage())
    ..insertRun(
      _run(
        'r1',
        'nightly',
        AutomationRunState.finished,
        const Duration(hours: 7),
        steps: [
          AutomationStepResult(
            kind: AutomationStepKind.tell,
            outcome: AutomationStepOutcome.skipped,
            detail: 'Not run: it is set to run only if something failed.',
            at: _now,
          ),
          AutomationStepResult(
            kind: AutomationStepKind.notify,
            outcome: AutomationStepOutcome.done,
            detail:
                'Notified: "Nightly tests and fixes in karmashala: '
                'succeeded"',
            at: _now,
          ),
        ],
      ),
    )
    ..insertRun(
      _run(
        'r2',
        'nightly',
        AutomationRunState.finished,
        const Duration(hours: 31),
      ),
    )
    ..insertRun(
      _run(
        'r3',
        'review',
        AutomationRunState.running,
        const Duration(minutes: 4),
        by: AutomationRunCause.runNow,
      ),
    )
    ..insertRunCheck(
      AutomationCheckVerdict(
        runId: 'r1',
        ordinal: 1,
        name: 'Test suite',
        command: const ['flutter', 'test'],
        verdict: VerificationVerdict.pass,
        reason: '6611 passed',
        checkedAt: _now,
      ),
    )
    ..insertRunCheck(
      AutomationCheckVerdict(
        runId: 'r2',
        ordinal: 1,
        name: 'Test suite',
        command: const ['flutter', 'test'],
        verdict: VerificationVerdict.fail,
        reason: '2 tests failed: activity_log_test.dart',
        checkedAt: _now,
      ),
    );
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(),
      await server.override(),
      clockProvider.overrideWithValue(FixedClock(_now)),
      runNowOfferedProvider.overrideWithValue(true),
      webhooksOfferedProvider.overrideWithValue(true),
    ],
  );
  container.read(automationControllerProvider).addCheck(
    'r1',
    'Test suite',
    const ['flutter', 'test'],
  );
  return container;
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    Directory(_outDir).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    required Brightness brightness,
    double textScale = 1,
    void Function(ProviderContainer container)? arrange,
    Future<void> Function(WidgetTester tester)? then,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = await tester.runAsync(_container);
    addTearDown(container!.dispose);
    arrange?.call(container);
    final key = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(body: AutomationsTabView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (then != null) await then(tester);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  void editNightly(ProviderContainer container) =>
      container.read(automationEditorProvider.notifier).edit(_nightly());

  for (final width in const <double>[360, 390, 1100, 1440, 1920]) {
    for (final scale in const [1.0, 1.6]) {
      testWidgets('grid $width at $scale', (tester) async {
        await shoot(
          tester,
          'grid-${width.toInt()}-x$scale',
          size: Size(width, 1000),
          brightness: Brightness.dark,
          textScale: scale,
        );
      });
    }
  }

  void runs(ProviderContainer container) => container
      .read(automationsSectionProvider.notifier)
      .show(AutomationsSection.runs);

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    for (final (form, size) in const [
      ('desktop', Size(1440, 1000)),
      ('phone', Size(390, 844)),
    ]) {
      testWidgets('list $form $theme', (tester) async {
        await shoot(
          tester,
          'list-$form-$theme',
          size: size,
          brightness: brightness,
        );
      });
      testWidgets('editor $form $theme', (tester) async {
        await shoot(
          tester,
          'editor-$form-$theme',
          size: form == 'desktop'
              ? const Size(1440, 1900)
              : const Size(390, 2600),
          brightness: brightness,
          arrange: editNightly,
        );
      });
      testWidgets('runs $form $theme', (tester) async {
        await shoot(
          tester,
          'runs-$form-$theme',
          size: size,
          brightness: brightness,
          arrange: runs,
          then: (tester) async {
            await tester.tap(find.textContaining('7h ago').first);
          },
        );
      });
    }
  }
}
