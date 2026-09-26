import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The chip is sized by what its host gives it, never by the window: a
/// terminal bar in a 1440px window is no wider for being in one (§6).
void main() {
  Future<double> chipWidth(WidgetTester tester, Size window) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: AgentIds.codex));
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: repository().id,
        agentInstallationId: agentInstallation(agentId: AgentIds.codex).id,
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
        // Codex's two axes: the longest label the chip draws.
        permissionMode: 'approval=on-request;sandbox=workspace-write',
      ),
    );

    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        ],
        child: const MaterialApp(
          home: Scaffold(
            // The terminal bar's host: a horizontal scroll, unbounded width.
            body: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: PermissionModeChip(sessionId: 's1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final width = tester.getSize(find.byType(PermissionModeChip)).width;
    await tester.pumpWidget(const SizedBox.shrink());
    return width;
  }

  testWidgets('the chip is as wide in a large window as in a small one', (
    tester,
  ) async {
    final small = await chipWidth(tester, const Size(720, 560));
    final large = await chipWidth(tester, const Size(1440, 900));
    expect(large, small);
  });
}
