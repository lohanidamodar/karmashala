import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/agent_status_badge.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/icons.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The explorer row of an ACP session says its lifecycle by its glyph**:
/// play while it runs — with the agent's own word on the badge beside it —
/// a check once it completed, a warning once it failed, a cross once it was
/// stopped. The question mark is for a process somebody could still be
/// running out of sight, which an ACP session never is.
void main() {
  late TestMachine db;

  setUp(() {
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    for (final (id, status) in [
      ('runs', SessionStatus.running),
      ('done', SessionStatus.completed),
      ('died', SessionStatus.failed),
      ('ended', SessionStatus.cancelled),
    ]) {
      server.sessionRows.insert(
        session(
          id: id,
          agentInstallationId: 'acp',
          title: 'Session $id',
          status: status,
        ),
      );
    }
  });

  testWidgets('each state has its glyph, and only the running row carries '
      'the agent\'s word', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => Stream.value(
              AgentStatusReport(
                agentId: AgentIds.claudeAcp,
                sessionId: 'agent-session',
                status: AgentActivityStatus.working,
                source: AgentStatusSource.protocol,
                observedAt: testTime,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();

    for (final title in ['runs', 'done', 'died', 'ended']) {
      expect(find.text('Session $title'), findsOneWidget);
    }
    // The ended rows say their lifecycle; the running row's glyph slot is
    // the badge — the agent's own word, here working — not a lifecycle icon.
    expect(find.byIcon(AppIcons.checkCircle), findsOneWidget);
    expect(find.byIcon(AppIcons.warningCircle), findsOneWidget);
    expect(find.byIcon(AppIcons.xCircle), findsOneWidget);
    expect(find.byIcon(AppIcons.question), findsNothing);
    expect(find.byIcon(AppIcons.playCircle), findsNothing);
    for (final word in ['Completed', 'Failed', 'Cancelled']) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == word,
        ),
        findsOneWidget,
        reason: word,
      );
    }
    expect(find.byType(AgentStatusBadge), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.startsWith("Working — from the agent's own") ??
                false),
      ),
      findsOneWidget,
    );
    // Running is said outright: the server runs it, no pane of ours need
    // vouch for it.
    expect(find.textContaining('no ending was reported'), findsNothing);
  });
}
