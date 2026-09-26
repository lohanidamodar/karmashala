import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/cli_detection/presentation/imported_session_view.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fixtures.dart';

/// The header's "open in a system terminal" menu.
///
/// Its rows were a hand-rolled `Row` in a plain `PopupMenuItem`; the Explorer's
/// menus a pane away were `DesktopMenuItem`. One list, one row.
void main() {
  const wt = SystemTerminal(
    kind: SystemTerminalKind.windowsTerminal,
    label: 'Windows Terminal',
    executable: 'wt.exe',
  );

  Future<void> pump(
    WidgetTester tester, {
    List<SystemTerminal> terminals = const [wt],
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i1',
        repositoryId: 'r1',
        cli: AgentIds.claudeCode,
        externalId: 'cli-abc',
        environmentId: 'windows',
        filePath: r'C:\store\cli-abc.jsonl',
        storeHome: r'C:\store',
        isSubagent: false,
        preview: 'the first thing said',
        title: 'Earlier work',
        createdAt: testTime,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => terminals,
          ),
          importedTranscriptProvider.overrideWith(
            (ref, id) => Stream.value([]),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ImportedSessionView(sessionId: 'i1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the external-terminal menu draws the house menu row', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Earlier work'), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.arrowSquareOut));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopMenuItem<SystemTerminal>), findsOneWidget);
    expect(find.text('Open in Windows Terminal'), findsOneWidget);
    expect(
      tester.getSize(find.byType(DesktopMenuItem<SystemTerminal>)).height,
      Chrome.menuRow,
    );
    // Icon-led, which a plain `PopupMenuItem` never is.
    expect(find.byIcon(AppIcons.terminal), findsOneWidget);
  });

  testWidgets('no terminals installed, no menu to open', (tester) async {
    await pump(tester, terminals: const []);
    expect(find.byIcon(AppIcons.arrowSquareOut), findsNothing);
  });
}
