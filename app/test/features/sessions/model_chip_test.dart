import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/presentation/model_picker.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_notice_line.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

/// An agent whose models are known and whose CLI cannot be told which to use.
///
/// Written for these tests rather than borrowed from a shipped agent, exactly
/// as `permission_mode_chip_test.dart` writes its own bypass-only CLI: all
/// three shipped agents take `--model`, so the "listed, disabled, explained"
/// row has no natural owner among them.
const _untellable = AgentDescriptor(
  id: 'untellable',
  displayName: 'Untellable CLI',
  binaries: AgentBinaries(windows: ['u'], posix: ['u']),
  launch: AgentLaunchSpec(
    model: AgentModelSupport.listedOnly(
      models: [AgentModel(id: 'big', label: 'Big', summary: 'The big one.')],
      evidence: 'invented for this test',
    ),
  ),
);

/// An agent nobody has recorded any models for. Draws no chip at all.
const _unknownModels = AgentDescriptor(
  id: 'unknownModels',
  displayName: 'Unknown CLI',
  binaries: AgentBinaries(windows: ['x'], posix: ['x']),
);

class Harness {
  Harness(this.db, this.container, this.sessionId, this.written);

  final AppDatabase db;
  final ProviderContainer container;
  final String sessionId;

  /// Everything typed into the session's pane since it started.
  final List<String> written;

  Widget get app => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        // The chip and the session bar it posts into, as both hosts compose
        // them: what a model change reports now belongs to this session rather
        // than to the window.
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SessionModelChip(sessionId: sessionId),
              SessionNoticeLine(sessionId: sessionId),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<Harness> harness(
  WidgetTester tester, {
  String agentId = AgentIds.claudeCode,
  AgentRegistry registry = AgentRegistry.builtIn,
  AgentActivityStatus status = AgentActivityStatus.idle,
  String? model,
  String? defaultModel,
}) async {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: agentId));
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(registry),
      settingsControllerProvider.overrideWith(
        () => _StaticSettings(
          defaultModel == null
              ? const Settings()
              : const Settings().withDefaultModel(agentId, defaultModel),
        ),
      ),
      sessionActivityLookupProvider.overrideWithValue((_) => status),
      sessionDirectoryPresentProvider.overrideWithValue((_) => true),
    ],
  );
  // A real launch, so the chip is bound to a session with a live (process-free)
  // pane — the only way the live-switch branch can be reached at all.
  final launched = await container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: agentId),
          title: 'Session',
          purpose: SessionPurpose.newSession,
        ),
      );
  final written = <String>[];
  container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(launched.paneId!)!
          .terminal
          .onOutput =
      written.add;
  if (model != null) SessionDao(db).updateModel(launched.session.id, model);
  return Harness(db, container, launched.session.id, written);
}

void main() {
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(ModelChip));
    await tester.pumpAndSettle();
  }

  testWidgets('a session that never chose says so, and names no model', (
    tester,
  ) async {
    final h = await harness(tester);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);

    // Not a fabricated `sonnet`: nothing was passed to the agent, and the chip
    // says exactly that.
    expect(find.text('default'), findsOneWidget);
    final tooltip = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .firstWhere((t) => (t.message ?? '').isNotEmpty);
    expect(tooltip.message, contains('No model is set for this session'));
  });

  testWidgets('the Settings default reaches the chip, named as a default', (
    tester,
  ) async {
    final h = await harness(tester, defaultModel: 'opus');
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);

    // The effective model, drawn as what it is: this session runs on Opus and
    // did not choose it.
    expect(find.text('Opus'), findsOneWidget);
    expect(find.text('· default'), findsOneWidget);
    final tooltip = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .firstWhere((t) => (t.message ?? '').isNotEmpty);
    expect(tooltip.message, contains('follows the Settings default'));

    await openMenu(tester);
    final back = tester
        .widgetList<DesktopMenuDetailItem<ModelChoice>>(
          find.byType(DesktopMenuDetailItem<ModelChoice>),
        )
        .first;
    // "Follow the default" is not an answer to "what will this run on", so the
    // row says what the default resolves to today.
    expect(back.value, ModelChoice.followDefault);
    expect(find.textContaining('Currently Opus'), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(
          DesktopMenuDetailItem<ModelChoice>,
          'Follow the Settings default',
        ),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
    // And only once: ticking Opus as well would read as a choice this session
    // made, which is the state that must not move when the setting does.
    expect(
      find.descendant(
        of: find.byType(DesktopMenuDetailItem<ModelChoice>),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a session that chose outranks the Settings default', (
    tester,
  ) async {
    final h = await harness(tester, model: 'sonnet', defaultModel: 'opus');
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);

    expect(find.text('Sonnet'), findsOneWidget);
    expect(find.text('· default'), findsNothing);
    expect(
      h.container
          .read(sessionLauncherProvider)
          .effectiveModelFor(h.sessionId)!
          .modelId,
      'sonnet',
    );
  });

  testWidgets('the chip shows the model the launcher resolves', (tester) async {
    final h = await harness(tester, model: 'opus');
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);

    // The descriptor's label, not the raw id — and the same value
    // `effectiveModelFor` hands the launch path.
    expect(find.text('Opus'), findsOneWidget);
    expect(
      h.container
          .read(sessionLauncherProvider)
          .effectiveModelFor(h.sessionId)!
          .modelId,
      'opus',
    );
  });

  testWidgets('a model this build has never heard of is still named', (
    tester,
  ) async {
    final h = await harness(tester, model: 'claude-opus-4-1');
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);

    expect(find.text('claude-opus-4-1'), findsOneWidget);
    expect(find.text('· unlisted'), findsOneWidget);

    await openMenu(tester);
    final rows = tester
        .widgetList<DesktopMenuDetailItem<ModelChoice>>(
          find.byType(DesktopMenuDetailItem<ModelChoice>),
        )
        .toList();
    final unlisted = rows.firstWhere(
      (r) => r.value?.modelId == 'claude-opus-4-1',
    );
    expect(unlisted.enabled, isFalse);
  });

  testWidgets('only models the descriptor can express are selectable', (
    tester,
  ) async {
    final h = await harness(
      tester,
      agentId: _untellable.id,
      registry: const AgentRegistry([DataOnlyAgentAdapter(_untellable)]),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    await openMenu(tester);

    // Listed — hiding it would leave the user wondering where the choice went
    // — disabled, and saying why.
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('not settable'), findsOneWidget);
    expect(find.textContaining('takes no model flag'), findsOneWidget);
    final row = tester
        .widgetList<DesktopMenuDetailItem<ModelChoice>>(
          find.byType(DesktopMenuDetailItem<ModelChoice>),
        )
        .firstWhere((r) => r.value?.modelId == 'big');
    expect(row.enabled, isFalse);
  });

  testWidgets('an agent whose models nobody recorded draws no chip', (
    tester,
  ) async {
    final h = await harness(
      tester,
      agentId: _unknownModels.id,
      registry: const AgentRegistry([DataOnlyAgentAdapter(_unknownModels)]),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);

    expect(find.byType(ModelChip), findsNothing);
  });

  testWidgets('the way back to the default is a row, not a null value', (
    tester,
  ) async {
    final h = await harness(tester, model: 'opus');
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    await openMenu(tester);

    // The trap `PermissionChoice` documents: a null menu value reads as a
    // dismissal and never reaches `onSelected`. The row's value is a
    // `ModelChoice` holding null, which is a value like any other.
    final first = tester
        .widgetList<DesktopMenuDetailItem<ModelChoice>>(
          find.byType(DesktopMenuDetailItem<ModelChoice>),
        )
        .first;
    expect(first.value, ModelChoice.followDefault);
    expect(first.value, isNotNull);
    expect(find.byType(DesktopMenuDivider), findsOneWidget);

    await tester.tap(find.text('Follow the Settings default'));
    await tester.pumpAndSettle();

    expect(SessionDao(h.db).getById(h.sessionId)!.modelId, isNull);
    expect(find.text('default'), findsOneWidget);
  });

  testWidgets('idle and slash-capable: sent now, and the chip says so', (
    tester,
  ) async {
    final h = await harness(tester);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    await openMenu(tester);

    // Every selectable row promises it *before* the click, too.
    expect(find.text('now'), findsNWidgets(4));

    await tester.tap(find.text('Opus'));
    await tester.pumpAndSettle();

    expect(h.written, ['/model opus', kEndOfLineKey, '\r']);
    expect(find.textContaining('switched now'), findsOneWidget);
    expect(find.textContaining('/model opus'), findsOneWidget);
    expect(SessionDao(h.db).getById(h.sessionId)!.modelId, 'opus');
    expect(find.text('Opus'), findsOneWidget);
  });

  testWidgets('working: nothing is typed, and the chip says after this turn', (
    tester,
  ) async {
    final h = await harness(tester, status: AgentActivityStatus.working);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    await openMenu(tester);

    expect(find.text('now'), findsNothing);
    expect(find.text('after this turn'), findsNWidgets(4));

    await tester.tap(find.text('Opus'));
    await tester.pumpAndSettle();

    expect(h.written, isEmpty);
    expect(find.textContaining('finishes this turn'), findsOneWidget);
    // The override is still recorded, so the next launch runs on it.
    expect(SessionDao(h.db).getById(h.sessionId)!.modelId, 'opus');
  });

  testWidgets('Codex, idle: its own picker opens, and the chip says so', (
    tester,
  ) async {
    final h = await harness(tester, agentId: AgentIds.codex);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    await openMenu(tester);

    await tester.tap(find.text('GPT-5.5'));
    await tester.pumpAndSettle();

    expect(h.written.join(), contains('/model'));
    expect(find.textContaining('opened its own model picker'), findsOneWidget);
    expect(SessionDao(h.db).getById(h.sessionId)!.modelId, 'gpt-5.5');
  });

  testWidgets('the menu draws the house two-line row, checked once', (
    tester,
  ) async {
    final h = await harness(tester, model: 'sonnet');
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    await tester.pumpWidget(h.app);
    await openMenu(tester);

    // Four models plus the way back to the default.
    expect(find.byType(DesktopMenuDetailItem<ModelChoice>), findsNWidgets(5));
    expect(
      find.descendant(
        of: find.byType(DesktopMenuDetailItem<ModelChoice>),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
  });
}
