import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

/// An agent whose only expressible mode is the most dangerous one.
///
/// Antigravity used to have this shape and no longer does — reading `agy
/// --help` showed all three modes map exactly — so the two tests about a mode
/// the descriptor *cannot* express need a descriptor written for them rather
/// than whichever shipped agent is least understood.
const _bypassOnly = AgentDescriptor(
  id: 'bypassOnly',
  displayName: 'Bypass-only CLI',
  binaries: AgentBinaries(windows: ['b'], posix: ['b']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.bypass: PermissionModeMapping.exact(['--yolo']),
    },
  ),
);

/// A session row for [agentId], carrying [mode] (null = inherit).
({AppDatabase db, ProviderScope app}) harness({
  required String agentId,
  PermissionMode? mode,
  Settings settings = const Settings(),
  AgentRegistry registry = AgentRegistry.builtIn,
  String? externalSessionId,
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: agentId));
  SessionDao(db).insert(
    Session(
      id: 's1',
      repositoryId: repository().id,
      agentInstallationId: agentInstallation(agentId: agentId).id,
      title: 'Session',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: testTime,
      surface: SessionSurface.pane,
      permissionMode: mode,
      // Only the restart path reads it, and only to refuse without one: a
      // relaunch with no conversation to name would open a blank one.
      externalSessionId: externalSessionId,
    ),
  );
  return (
    db: db,
    app: ProviderScope(
      overrides: [
        // Already overrides `databaseProvider`; a second one asserts.
        ...fakeTerminalOverrides(database: db),
        agentRegistryProvider.overrideWithValue(registry),
        settingsControllerProvider.overrideWith(
          () => _StaticSettings(settings),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: PermissionModeChip(sessionId: 's1')),
        ),
      ),
    ),
  );
}

/// Puts a live agent pane behind `s1`, which is what makes it a session with
/// something to restart.
///
/// Built through the real controller rather than by writing a pane id onto the
/// row, because `livePaneFor` asks three separate questions — the row names a
/// pane, that pane has an instance, and the instance says it is live — and a
/// fake that satisfies only the first would make every test here pass without
/// exercising the end-and-relaunch this feature is.
String startAgent(WidgetTester tester, AppDatabase db) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(PermissionModeChip)),
  );
  final opened = container
      .read(terminalSessionsControllerProvider.notifier)
      .openAgentTab(
        const AgentPaneLaunch(
          agentId: AgentIds.claudeCode,
          executable: r'C:\Users\me\.bin\claude.exe',
          arguments: [],
          workingDirectory: r'C:\src\demo\app',
          sessionId: 's1',
          title: 'Session',
        ),
      );
  SessionDao(db).updatePaneId('s1', opened.paneId);
  return opened.paneId;
}

void main() {
  testWidgets('shows the session\'s own mode, not the agent default', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.acceptEdits,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: PermissionMode.bypass),
      ),
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    // The row says acceptEdits; the agent default says bypass. The chip must
    // show what this session will actually run under.
    expect(find.text('Accept edits'), findsOneWidget);
    expect(find.text('Bypass'), findsNothing);
    // Claude Code expresses it exactly, so no fidelity qualifier is drawn.
    expect(find.textContaining('· '), findsNothing);
  });

  testWidgets('marks an approximate mapping on the chip itself', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.codex,
      mode: PermissionMode.acceptEdits,
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    // Not only in the tooltip: "Accept edits" that is really Codex's
    // sandbox mode has to look different from one that really is accept-edits.
    expect(find.text('Accept edits'), findsOneWidget);
    expect(find.text('· approximate'), findsOneWidget);
  });

  testWidgets('says so when the agent cannot be told at all', (tester) async {
    final h = harness(
      agentId: _bypassOnly.id,
      mode: PermissionMode.ask,
      registry: const AgentRegistry([_bypassOnly]),
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('· not enforced'), findsOneWidget);
  });

  testWidgets('offers only the modes the descriptor can express', (
    tester,
  ) async {
    final h = harness(
      agentId: _bypassOnly.id,
      mode: PermissionMode.ask,
      registry: const AgentRegistry([_bypassOnly]),
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();

    // All three are listed — hiding them would leave the user wondering where
    // the safe option went — but only bypass can be chosen.
    for (final mode in PermissionMode.values) {
      expect(find.text(mode.label), findsOneWidget, reason: mode.name);
    }
    PopupMenuItem<PermissionChoice> item(PermissionMode mode) => tester
        .widgetList<PopupMenuItem<PermissionChoice>>(
          find.byType(PopupMenuItem<PermissionChoice>),
        )
        .firstWhere((w) => w.value?.mode == mode);

    expect(item(PermissionMode.ask).enabled, isFalse);
    expect(item(PermissionMode.acceptEdits).enabled, isFalse);
    expect(item(PermissionMode.bypass).enabled, isTrue);
  });

  testWidgets('choosing a mode writes the row and says when it applies', (
    tester,
  ) async {
    final h = harness(agentId: AgentIds.claudeCode, mode: PermissionMode.ask);
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.acceptEdits.label));
    await tester.pumpAndSettle();

    expect(
      SessionDao(h.db).getById('s1')!.permissionMode,
      PermissionMode.acceptEdits,
    );
    // Never claims the running agent changed: it was started with the old
    // flags and no CLI here can be re-governed mid-session.
    expect(find.textContaining('applies'), findsOneWidget);
    expect(find.text('Accept edits'), findsOneWidget);
  });

  testWidgets('an inherited mode is labelled as inherited in the tooltip', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: PermissionMode.acceptEdits),
      ),
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    // Null column: the row predates v11 or was never overridden, so the agent
    // default is the answer — and the tooltip says that is where it came from.
    expect(find.text('Accept edits'), findsOneWidget);
    // PopupMenuButton contributes a Tooltip of its own; the chip's is the one
    // carrying a message.
    final tooltip = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .firstWhere((t) => (t.message ?? '').isNotEmpty);
    expect(tooltip.message, contains('Following'));
    expect(tooltip.message, contains('Settings'));
  });

  testWidgets('a session following the default says so on the chip', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: PermissionMode.acceptEdits),
      ),
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    // Honest on the face of the control, not only on hover: this session never
    // chose acceptEdits, it is tracking a setting that can move under it, and
    // drawing the resolved value bare would read as a decision it made.
    expect(find.text('Accept edits'), findsOneWidget);
    expect(find.text('· default'), findsOneWidget);
  });

  testWidgets('a chosen mode is not labelled as the default', (tester) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.acceptEdits,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: PermissionMode.acceptEdits),
      ),
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    // Same resolved mode as the test above, different state, and the two must
    // not look alike — this one stays put when the setting moves.
    expect(find.text('· default'), findsNothing);
  });

  testWidgets('the menu offers the way back to the default', (tester) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.bypass,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: PermissionMode.ask),
      ),
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow the Settings default'));
    await tester.pumpAndSettle();

    // Clearing the row is the only way back: without it the first pick would
    // be irreversible, and "follow the default" would be a state the user
    // could leave but never re-enter.
    expect(SessionDao(h.db).getById('s1')!.permissionMode, isNull);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('· default'), findsOneWidget);
  });

  // --- applying a mode to the session that is running now --------------------

  testWidgets('picking bypass asks first, and cancelling changes nothing', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.ask,
      externalSessionId: 'ext-1',
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.bypass.label));
    await tester.pumpAndSettle();

    expect(find.text('${PermissionMode.bypass.label}?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // "Cancel" has to mean the session is as the user found it. Writing the
    // row first and offering to undo would be a weaker promise: the mode would
    // already be recorded, and any other surface resuming this session would
    // honour it.
    expect(SessionDao(h.db).getById('s1')!.permissionMode, PermissionMode.ask);
    expect(SessionDao(h.db).getById('s1')!.paneId, pane);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PermissionModeChip)),
    );
    expect(
      container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(pane),
      isNotNull,
    );
  });

  testWidgets('the bypass dialog names all three things it costs', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.ask,
      externalSessionId: 'ext-1',
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);
    startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.bypass.label));
    await tester.pumpAndSettle();

    // The prompts, which the chip's colour already hints at.
    expect(find.textContaining('without asking'), findsOneWidget);
    // The turn in flight, which nothing else in the app would tell them.
    expect(find.textContaining('that work is lost'), findsOneWidget);
    // And the bill. Resuming reads the transcript back from disk for nothing;
    // the next message is what carries it all to the model, and a user who
    // finds that out from an invoice was not warned.
    expect(find.textContaining('as context'), findsOneWidget);
  });

  testWidgets('confirming bypass writes the row and restarts the agent', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.ask,
      externalSessionId: 'ext-1',
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.bypass.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart in bypass'));
    await tester.pumpAndSettle();

    expect(
      SessionDao(h.db).getById('s1')!.permissionMode,
      PermissionMode.bypass,
    );

    // A second process, on the same conversation, carrying the flags the first
    // one could not be told about.
    final terminals = ProviderScope.containerOf(
      tester.element(find.byType(PermissionModeChip)),
    ).read(terminalSessionsControllerProvider.notifier);
    final restarted = SessionDao(h.db).getById('s1')!.paneId!;
    expect(restarted, isNot(pane));
    expect(terminals.instanceFor(pane), isNull);
    final arguments = terminals.instanceFor(restarted)!.agentLaunch!.arguments;
    expect(
      arguments,
      containsAllInOrder(['--permission-mode', 'bypassPermissions']),
    );
    expect(arguments, containsAllInOrder(['--resume', 'ext-1']));
  });

  testWidgets('a safe mode offers the restart instead of performing it', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.ask,
      externalSessionId: 'ext-1',
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.acceptEdits.label));
    await tester.pumpAndSettle();

    // Nothing was ended. Accept-edits is not dangerous, so it earns no dialog
    // — but a mode change must not silently kill an agent either, so the
    // restart is an offer.
    expect(SessionDao(h.db).getById('s1')!.paneId, pane);
    expect(find.text('Restart to apply'), findsOneWidget);
    // And the offer is honest before it is taken: a snackbar action is one tap
    // with no dialog behind it, so both costs are in the message itself.
    expect(find.textContaining('ends the agent running now'), findsOneWidget);
    expect(find.textContaining('re-sends the conversation'), findsOneWidget);
  });

  testWidgets('the restart offer performs the restart when it is taken', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.ask,
      externalSessionId: 'ext-1',
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.acceptEdits.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart to apply'));
    await tester.pumpAndSettle();

    final terminals = ProviderScope.containerOf(
      tester.element(find.byType(PermissionModeChip)),
    ).read(terminalSessionsControllerProvider.notifier);
    final restarted = SessionDao(h.db).getById('s1')!.paneId!;
    expect(restarted, isNot(pane));
    expect(terminals.instanceFor(pane), isNull);
    expect(
      terminals.instanceFor(restarted)!.agentLaunch!.arguments,
      containsAllInOrder(['--resume', 'ext-1']),
    );
  });

  testWidgets('with nothing running there is nothing to restart', (
    tester,
  ) async {
    final h = harness(
      agentId: AgentIds.claudeCode,
      mode: PermissionMode.ask,
      externalSessionId: 'ext-1',
    );
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.acceptEdits.label));
    await tester.pumpAndSettle();

    // "Applies when this session next runs" is already the whole truth here,
    // and a Restart button would be offering to solve a problem the user does
    // not have.
    expect(find.text('Restart to apply'), findsNothing);
  });

  testWidgets('a session the CLI has never named refuses the restart', (
    tester,
  ) async {
    final h = harness(agentId: AgentIds.claudeCode, mode: PermissionMode.ask);
    addTearDown(h.db.close);
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(PermissionMode.acceptEdits.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart to apply'));
    await tester.pumpAndSettle();

    // The row has no conversation id, so a relaunch would open a blank one.
    // The agent holding the history keeps running, and the message says both
    // that the restart failed and that the choice was kept — without the
    // second half the user re-picks a mode that is already set.
    //
    // Asked of the instance, not of the row: the row goes on naming a pane
    // long after that pane has been disposed, so a paneId check alone would
    // pass for a refusal that killed the agent on its way out.
    expect(SessionDao(h.db).getById('s1')!.paneId, pane);
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(PermissionModeChip)),
      ).read(terminalSessionsControllerProvider.notifier).instanceFor(pane),
      isNotNull,
    );
    expect(
      SessionDao(h.db).getById('s1')!.permissionMode,
      PermissionMode.acceptEdits,
    );
    expect(find.textContaining('new conversation'), findsOneWidget);
    expect(find.textContaining('is saved'), findsOneWidget);
  });
}
