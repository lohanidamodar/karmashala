import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/session_more_button.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart'
    show kPermissionCycleSettle;
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_agent_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_notice_line.dart';
import 'package:karmashala_session/launch.dart' show SessionSurface;
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The session's own controls in the dashboard's peek** (round 56, item
/// 6): the bar's widgets — not copies — so a choice made in the peek is the
/// one the session's tab shows.
void main() {
  late TestMachine db;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(820, 600),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: repository().id,
        agentInstallationId: agentInstallation(agentId: AgentIds.claudeCode).id,
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
        permissionMode: 'mode=manual',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await server.override(),
          ...fakeTerminalOverrides(machine: db),
          conversationPresenceProvider.overrideWithValue(
            ({
              required descriptor,
              required environmentId,
              required conversationId,
            }) async => ConversationPresence.unknown,
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OverviewPeekControls(sessionId: 's1'),
                // What the session's own tab draws on its bar.
                KeyedSubtree(
                  key: ValueKey('the-tab'),
                  child: PermissionModeChip(sessionId: 's1'),
                ),
                SessionNoticeLine(sessionId: 's1'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inPeek(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('overview-peek-controls')),
    matching: matching,
  );

  testWidgets('the bar\'s own controls, each for this session', (tester) async {
    await pump(tester);

    expect(
      tester.widget<SessionAgentChip>(inPeek(find.byType(SessionAgentChip))),
      isA<SessionAgentChip>().having((c) => c.sessionId, 'sessionId', 's1'),
    );
    expect(inPeek(find.byType(PermissionModeChip)), findsOneWidget);
    expect(
      tester.widget<DeliveryStrip>(inPeek(find.byType(DeliveryStrip))),
      isA<DeliveryStrip>().having((c) => c.sessionId, 'sessionId', 's1'),
    );
    expect(
      tester.widget<SessionMoreButton>(inPeek(find.byType(SessionMoreButton))),
      isA<SessionMoreButton>().having((c) => c.sessionId, 'sessionId', 's1'),
    );
  });

  testWidgets('a permission chosen in the peek is the one the tab shows', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(inPeek(find.byType(PermissionModeChip)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build · Accept edits').last);
    await tester.pumpAndSettle();
    await tester.pump(kPermissionCycleSettle * 2);
    await tester.pumpAndSettle();

    expect(
      db.server.sessionRows.getById('s1')!.permissionMode,
      'mode=acceptEdits',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('the-tab')),
        matching: find.text('Build · Accept edits'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('at 360 px and text scale 1.6 it fits, ⋯ in reach', (
    tester,
  ) async {
    await pump(tester, size: const Size(360, 640), textScale: 1.6);

    expect(tester.takeException(), isNull);
    final more = tester.getRect(inPeek(find.byType(SessionMoreButton)));
    expect(more.right, lessThanOrEqualTo(360));
  });
}
