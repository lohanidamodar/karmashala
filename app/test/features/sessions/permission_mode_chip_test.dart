import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/sessions/presentation/session_notice_line.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart' show SessionResume;
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

/// An agent nobody has established the modes of.
///
/// The shape the chip has to answer honestly rather than with a menu of
/// guesses. No shipped agent has it, so it needs a descriptor written for it
/// rather than whichever CLI happens to be least understood.
const _unestablished = AgentDescriptor(
  id: 'unestablished',
  displayName: 'Unestablished CLI',
  binaries: AgentBinaries(windows: ['u'], posix: ['u']),
  launch: AgentLaunchSpec(),
);

// Claude Code's own ids, which is what a session row holds after v35.
const _ask = 'mode=manual';
const _acceptEdits = 'mode=acceptEdits';
const _bypass = 'mode=bypassPermissions';
const _bypassLabel = 'Bypass (full autonomy)';

/// A session row for [agentId], carrying [mode] (null = inherit).
Future<({TestMachine db, ProviderScope app})> harness({
  required String agentId,
  String? mode,
  Settings settings = const Settings(),
  AgentRegistry registry = AgentRegistry.builtIn,
  String? externalSessionId,
}) async {
  final db = TestMachine();
  final server = FakeDataServer()..runsOn(db);
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  server.installationRows.insert(agentInstallation(agentId: agentId));
  db.server.sessionRows.insert(
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
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        // Hermetic: the real probe would read this machine's own agent store.
        conversationPresenceProvider.overrideWithValue(
          ({
            required descriptor,
            required environmentId,
            required conversationId,
          }) async => ConversationPresence.unknown,
        ),
        agentRegistryProvider.overrideWithValue(registry),
        settingsControllerProvider.overrideWith(
          () => _StaticSettings(settings),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          // The chip *and* the bar it posts into, because that is how both
          // hosts compose them: what the chip says now lands in the session's
          // own bar, and a harness holding only the chip would leave every
          // message here with nowhere to be drawn.
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PermissionModeChip(sessionId: 's1'),
                SessionNoticeLine(sessionId: 's1'),
              ],
            ),
          ),
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
String startAgent(WidgetTester tester, TestMachine db) {
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
  db.server.sessionRows.updatePaneId('s1', opened.paneId);
  return opened.paneId;
}

void main() {
  testWidgets('shows the session\'s own mode, not the agent default', (
    tester,
  ) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _acceptEdits,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: _bypass),
      ),
    );
    await tester.pumpWidget(h.app);

    // The row says acceptEdits; the agent default says bypass. The chip must
    // show what this session will actually run under.
    expect(find.text('Build · Accept edits'), findsOneWidget);
    expect(find.text('Bypass'), findsNothing);
    // Claude Code expresses it exactly, so no fidelity qualifier is drawn.
    // The '· ' the face does carry is the rung's borrowed name, which is part
    // of the mode's own label and not a qualifier.
    expect(find.textContaining('· default'), findsNothing);
    expect(find.textContaining('· unrecognised'), findsNothing);
    expect(find.textContaining('approximate'), findsNothing);
  });

  testWidgets('the chip names the rung beside the CLI own word', (
    tester,
  ) async {
    // The face is the one surface with a third of a window to live in, and it
    // is still both halves: the borrowed name earns its place by being the
    // word that is the same across three CLIs, and the CLI's own word is what
    // a person configuring that CLI needs.
    final h = await harness(agentId: AgentIds.claudeCode, mode: _acceptEdits);
    await tester.pumpWidget(h.app);

    expect(find.text('Build · Accept edits'), findsOneWidget);
  });

  testWidgets('and says it once where the CLI already says it', (tester) async {
    final h = await harness(agentId: AgentIds.claudeCode, mode: 'mode=plan');
    await tester.pumpWidget(h.app);

    // "Plan · Plan" is not clearer than "Plan".
    expect(find.text('Plan'), findsOneWidget);
  });

  testWidgets('draws both of Codex\'s axes on the chip', (tester) async {
    // The old chip said "Accept edits · approximate" here, because a shared
    // three-value mode had to stand in for two independent flags. There is no
    // approximation left to mark: the chip names what Codex will actually be
    // told, on both axes.
    final h = await harness(
      agentId: AgentIds.codex,
      mode: 'approval=on-request;sandbox=workspace-write',
    );
    await tester.pumpWidget(h.app);

    // Two axes, so the CLI's own words are bracketed behind the one borrowed
    // name — the reader can tell which word came from where.
    expect(find.text('Build (Workspace · On request)'), findsOneWidget);
    expect(find.textContaining('approximate'), findsNothing);
  });

  testWidgets('says so when the agent\'s modes are not established', (
    tester,
  ) async {
    final h = await harness(
      agentId: _unestablished.id,
      registry: const AgentRegistry([DataOnlyAgentAdapter(_unestablished)]),
    );
    await tester.pumpWidget(h.app);

    expect(find.text('Not established'), findsOneWidget);
  });

  testWidgets('an agent with no established modes offers one explained row', (
    tester,
  ) async {
    final h = await harness(
      agentId: _unestablished.id,
      registry: const AgentRegistry([DataOnlyAgentAdapter(_unestablished)]),
    );
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();

    // The disabled-with-a-reason affordance, in the shape that survives when
    // the *list itself* is unknown: one row saying so, rather than an empty
    // menu or a set of guesses.
    expect(find.text('No permission modes established'), findsOneWidget);
    expect(find.textContaining('Unestablished CLI'), findsWidgets);
    final row = tester.widget<DesktopMenuDetailItem<PermissionChoice>>(
      find.widgetWithText(
        DesktopMenuDetailItem<PermissionChoice>,
        'No permission modes established',
      ),
    );
    expect(row.enabled, isFalse);
  });

  testWidgets('a superseded axis is listed, disabled, and says why', (
    tester,
  ) async {
    // Codex's bypass flag replaces the approval policy outright, so those rows
    // are shown greyed rather than hidden — the same rule, now doing its work
    // on an axis instead of on a mode the CLI never had.
    final h = await harness(
      agentId: AgentIds.codex,
      mode: 'approval=on-request;sandbox=bypass-all',
    );
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();

    expect(find.textContaining('nothing set here is passed'), findsWidgets);
    final row = tester.widget<DesktopMenuDetailItem<PermissionChoice>>(
      find.widgetWithText(DesktopMenuDetailItem<PermissionChoice>, 'Never ask'),
    );
    expect(row.enabled, isFalse);
  });

  testWidgets('a mode this build does not name is flagged, not shown as ours', (
    tester,
  ) async {
    // A row written by a newer build. `resolveStored` substitutes the agent's
    // default, which is the only thing it can do — but the chip must not draw
    // the substitute as if the user had picked it.
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: 'mode=somethingNewer',
    );
    await tester.pumpWidget(h.app);

    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('· unrecognised'), findsOneWidget);
    final tooltip = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .firstWhere((t) => (t.message ?? '').isNotEmpty);
    expect(tooltip.message, contains('does not name'));
  });

  testWidgets('the menu draws the house two-line row', (tester) async {
    // Its rows were a `Row`/`Column` of their own inside a plain
    // `PopupMenuItem`; the Explorer's menus a pane away were `DesktopMenuItem`.
    final h = await harness(agentId: AgentIds.claudeCode, mode: _ask);
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();

    // Claude Code's six modes, plus the "follow the default" row above the
    // divider.
    expect(
      find.byType(DesktopMenuDetailItem<PermissionChoice>),
      findsNWidgets(7),
    );
    expect(find.byType(DesktopMenuDivider), findsOneWidget);
    expect(
      tester
          .getSize(
            find.widgetWithText(
              DesktopMenuDetailItem<PermissionChoice>,
              'Follow the Settings default',
            ),
          )
          .height,
      greaterThanOrEqualTo(Chrome.menuRowTall),
    );
    // The mode this session actually holds is the checked one, and only it.
    expect(
      find.descendant(
        of: find.byType(DesktopMenuDetailItem<PermissionChoice>),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('choosing a mode writes the row and says when it applies', (
    tester,
  ) async {
    final h = await harness(agentId: AgentIds.claudeCode, mode: _ask);
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build · Accept edits'));
    await tester.pumpAndSettle();
    // The live switch is tried first; this pane never redraws its mode, so it
    // gives up after the redraw window and the restart is offered instead.
    await tester.pump(kPermissionCycleSettle * 2);
    await tester.pumpAndSettle();

    expect(h.db.server.sessionRows.getById('s1')!.permissionMode, _acceptEdits);
    // Never claims the running agent changed: it was started with the old
    // flags and no CLI here can be re-governed mid-session.
    expect(find.textContaining('applies'), findsOneWidget);
    expect(find.text('Build · Accept edits'), findsOneWidget);
  });

  testWidgets('an inherited mode is labelled as inherited in the tooltip', (
    tester,
  ) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: _acceptEdits),
      ),
    );
    await tester.pumpWidget(h.app);

    // Null column: the row predates v11 or was never overridden, so the agent
    // default is the answer — and the tooltip says that is where it came from.
    expect(find.text('Build · Accept edits'), findsOneWidget);
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
    final h = await harness(
      agentId: AgentIds.claudeCode,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: _acceptEdits),
      ),
    );
    await tester.pumpWidget(h.app);

    // Honest on the face of the control, not only on hover: this session never
    // chose acceptEdits, it is tracking a setting that can move under it, and
    // drawing the resolved value bare would read as a decision it made.
    expect(find.text('Build · Accept edits'), findsOneWidget);
    expect(find.text('· default'), findsOneWidget);
  });

  testWidgets('a chosen mode is not labelled as the default', (tester) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _acceptEdits,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: _acceptEdits),
      ),
    );
    await tester.pumpWidget(h.app);

    // Same resolved mode as the test above, different state, and the two must
    // not look alike — this one stays put when the setting moves.
    expect(find.text('· default'), findsNothing);
  });

  testWidgets('the menu offers the way back to the default', (tester) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _bypass,
      settings: const Settings().withPermissions(
        AgentIds.claudeCode,
        const AgentPermissions(existingSessions: _ask),
      ),
    );
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow the Settings default'));
    await tester.pumpAndSettle();

    // Clearing the row is the only way back: without it the first pick would
    // be irreversible, and "follow the default" would be a state the user
    // could leave but never re-enter.
    expect(h.db.server.sessionRows.getById('s1')!.permissionMode, isNull);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('· default'), findsOneWidget);
  });

  // --- applying a mode to the session that is running now --------------------

  testWidgets('picking bypass asks first, and cancelling changes nothing', (
    tester,
  ) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _ask,
      externalSessionId: 'ext-1',
    );
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_bypassLabel));
    await tester.pumpAndSettle();

    expect(find.text('$_bypassLabel?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // "Cancel" has to mean the session is as the user found it. Writing the
    // row first and offering to undo would be a weaker promise: the mode would
    // already be recorded, and any other surface resuming this session would
    // honour it.
    expect(h.db.server.sessionRows.getById('s1')!.permissionMode, _ask);
    expect(h.db.server.sessionRows.getById('s1')!.paneId, pane);
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
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _ask,
      externalSessionId: 'ext-1',
    );
    await tester.pumpWidget(h.app);
    startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_bypassLabel));
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
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _ask,
      externalSessionId: 'ext-1',
    );
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_bypassLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart in $_bypassLabel'));
    await tester.pumpAndSettle();

    expect(h.db.server.sessionRows.getById('s1')!.permissionMode, _bypass);

    // Asked of the server, which ends the agent and starts it again on the
    // same conversation with the mode the row now holds (slice 5b).
    final restart = h.db.server.sessionWork.asked
        .whereType<SessionResume>()
        .single;
    expect((restart.sessionId, restart.restart), ('s1', true));
    expect(h.db.server.sessionRows.getById('s1')!.paneId, pane);
  });

  testWidgets('a safe mode offers the restart instead of performing it', (
    tester,
  ) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _ask,
      externalSessionId: 'ext-1',
    );
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build · Accept edits'));
    await tester.pumpAndSettle();
    // The live switch is tried first; this pane never redraws its mode, so it
    // gives up after the redraw window and the restart is offered instead.
    await tester.pump(kPermissionCycleSettle * 2);
    await tester.pumpAndSettle();

    // Nothing was ended. Accept-edits is not dangerous, so it earns no dialog
    // — but a mode change must not silently kill an agent either, so the
    // restart is an offer.
    expect(h.db.server.sessionRows.getById('s1')!.paneId, pane);
    expect(find.text('Restart to apply'), findsOneWidget);
    // And the offer is honest before it is taken: it is one tap with no dialog
    // behind it, so both costs are in the message itself.
    expect(find.textContaining('ends the agent running now'), findsOneWidget);
    expect(find.textContaining('re-sends the conversation'), findsOneWidget);
    // In this session's bar and nowhere else. A snackbar put it across the
    // bottom of the window, covering the status bar to report something that
    // was true of one session out of however many were open.
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the restart offer performs the restart when it is taken', (
    tester,
  ) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _ask,
      externalSessionId: 'ext-1',
    );
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build · Accept edits'));
    await tester.pumpAndSettle();
    // The live switch is tried first; this pane never redraws its mode, so it
    // gives up after the redraw window and the restart is offered instead.
    await tester.pump(kPermissionCycleSettle * 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart to apply'));
    await tester.pumpAndSettle();

    // The restart is the server's (slice 5b): it ends the agent and resumes
    // the conversation in the same terminal, which the pane stays on.
    final restart = h.db.server.sessionWork.asked
        .whereType<SessionResume>()
        .single;
    expect((restart.sessionId, restart.restart), ('s1', true));
    expect(h.db.server.sessionRows.getById('s1')!.paneId, pane);
  });

  testWidgets('with nothing running there is nothing to restart', (
    tester,
  ) async {
    final h = await harness(
      agentId: AgentIds.claudeCode,
      mode: _ask,
      externalSessionId: 'ext-1',
    );
    await tester.pumpWidget(h.app);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build · Accept edits'));
    await tester.pumpAndSettle();
    // The live switch is tried first; this pane never redraws its mode, so it
    // gives up after the redraw window and the restart is offered instead.
    await tester.pump(kPermissionCycleSettle * 2);
    await tester.pumpAndSettle();

    // "Applies when this session next runs" is already the whole truth here,
    // and a Restart button would be offering to solve a problem the user does
    // not have.
    expect(find.text('Restart to apply'), findsNothing);
  });

  testWidgets('a session the CLI has never named refuses the restart', (
    tester,
  ) async {
    final h = await harness(agentId: AgentIds.claudeCode, mode: _ask);
    await tester.pumpWidget(h.app);
    final pane = startAgent(tester, h.db);

    await tester.tap(find.byType(PermissionModeChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build · Accept edits'));
    await tester.pumpAndSettle();
    // The live switch is tried first; this pane never redraws its mode, so it
    // gives up after the redraw window and the restart is offered instead.
    await tester.pump(kPermissionCycleSettle * 2);
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
    expect(h.db.server.sessionRows.getById('s1')!.paneId, pane);
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(PermissionModeChip)),
      ).read(terminalSessionsControllerProvider.notifier).instanceFor(pane),
      isNotNull,
    );
    expect(h.db.server.sessionRows.getById('s1')!.permissionMode, _acceptEdits);
    expect(find.textContaining('new conversation'), findsOneWidget);
    expect(find.textContaining('is saved'), findsOneWidget);
  });
}
