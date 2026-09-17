import 'package:agent_cli/descriptors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_tree_rows.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_dao.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **One indentation rhythm and one right-hand column, for every row kind.**
///
/// The owner's screenshot of the Explorer: the machine, `PROJECTS`, the context
/// groups, the project and its sessions each stepped in by a different amount;
/// counts, `+` and ages ended in different columns; project and session rows
/// were tinted cards among flat headers; a running session drew its status
/// twice. Measured on the real panel, not on the kit widgets alone.
const _width = 360.0;
const _long = 'popupbits-ai-workspace-with-a-long-name';

class _Inbox extends AttentionInboxController {
  @override
  AttentionInbox build() => AttentionInbox(
    items: [
      InboxItem(
        session: const WatchedSession(
          key: AgentSessionKey('claude-code', 'unread'),
          label: 'Unread session',
          openId: 's-unread',
          imported: false,
        ),
        kind: InboxItemKind.finished,
        at: testTime,
      ),
    ],
  );
}

void main() {
  AppDatabase seeded() {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    WorkspaceDao(
      db,
    ).insert(Workspace(id: 'w1', name: 'Game dev', createdAt: testTime));
    ProjectDao(db).insert(
      project(id: 'p1', name: _long, path: r'C:\src\p1', workspaceId: 'w1'),
    );
    ProjectDao(db).insert(project(id: 'p2', name: 'Loose', path: r'C:\p2'));
    RepositoryDao(
      db,
    ).insert(repository(id: 'r1', projectId: 'p1', path: r'C:\src\p1'));
    AgentInstallationDao(db).insert(agentInstallation());
    for (final (id, title, status) in [
      ('s-run', 'Running session', SessionStatus.running),
      ('s-unk', 'Unknown session', SessionStatus.unknown),
      ('s-done', 'Finished session', SessionStatus.completed),
      ('s-unread', 'Unread session', SessionStatus.completed),
    ]) {
      SessionDao(db).insert(session(id: id, title: title, status: status));
    }
    return db;
  }

  Future<void> pumpExplorer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = seeded();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
          attentionInboxProvider.overrideWith(_Inbox.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.macOS),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: _width,
                height: 800,
                child: Material(child: ExplorerPanel()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(_long));
    await tester.pumpAndSettle();
  }

  Finder rowOf(Type type) => find.byType(type);

  Finder sessionRow(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(ExplorerNativeSessionRow),
  );

  double centreX(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx;

  Finder chevronIn(Finder row) => find.descendant(
    of: row,
    matching: find.byWidgetPredicate(
      (w) =>
          w is Icon &&
          (w.icon == AppIcons.caretDown || w.icon == AppIcons.caretRight),
    ),
  );

  final statusIcons = [
    AppIcons.playCircle,
    AppIcons.checkCircle,
    AppIcons.question,
    AppIcons.warningCircle,
    AppIcons.xCircle,
    AppIcons.circleHalf,
    AppIcons.circle,
  ];

  Finder statusGlyphsIn(Finder row) => find.descendant(
    of: row,
    matching: find.byWidgetPredicate(
      (w) => (w is Icon && statusIcons.contains(w.icon)) || w is WorkingSpinner,
    ),
  );

  /// The count or age a row ends in: a number, `n projects`, `now`, `22h 3m`.
  final meta = RegExp(
    r'^(\d+( projects?| sessions?)?|now|\d+[mhd]( \d+[mh])?)$',
  );

  double metaRight(WidgetTester tester, Finder row) {
    final texts = find
        .descendant(of: row, matching: find.byType(Text))
        .evaluate()
        .where((e) => meta.hasMatch(_plain(e.widget as Text)))
        .toList();
    expect(texts, isNotEmpty, reason: 'a count or an age in $row');
    return texts
        .map((e) => tester.getTopRight(find.byWidget(e.widget).first).dx)
        .reduce((a, b) => a > b ? a : b);
  }

  List<Color> fillsIn(WidgetTester tester, Finder row) => tester
      .widgetList<DecoratedBox>(
        find.descendant(of: row, matching: find.byType(DecoratedBox)),
      )
      .map((b) => b.decoration)
      .whereType<BoxDecoration>()
      .map((d) => d.color)
      .whereType<Color>()
      .where((c) => c.a > 0)
      .toList();

  testWidgets('every depth steps in by one constant', (tester) async {
    await pumpExplorer(tester);

    final machine = centreX(tester, chevronIn(rowOf(ExplorerEnvironmentRow)));
    final section = centreX(
      tester,
      chevronIn(rowOf(ExplorerSectionHeaderRow)).first,
    );
    final group = centreX(tester, chevronIn(rowOf(ExplorerContextRow)));
    final project = centreX(
      tester,
      chevronIn(
        find.ancestor(
          of: find.text(_long),
          matching: find.byType(ExplorerProjectRow),
        ),
      ),
    );
    final step = section - machine;
    expect(step, greaterThan(0));
    expect(group - section, moreOrLessEquals(step, epsilon: 0.5));
    expect(project - group, moreOrLessEquals(step, epsilon: 0.5));

    // A session's one glyph sits one step right of its project's folder glyph.
    final folder = centreX(
      tester,
      find.descendant(
        of: find.byType(ExplorerProjectRow).first,
        matching: find.byIcon(AppIcons.folderOpen),
      ),
    );
    final glyph = centreX(
      tester,
      statusGlyphsIn(sessionRow('Finished session')).first,
    );
    expect(glyph - folder, moreOrLessEquals(step, epsilon: 0.5));
  });

  testWidgets('counts and ages end in one column on every row kind', (
    tester,
  ) async {
    await pumpExplorer(tester);

    final edges = {
      'machine': metaRight(tester, rowOf(ExplorerEnvironmentRow)),
      'section': metaRight(tester, rowOf(ExplorerSectionHeaderRow).first),
      'group': metaRight(tester, rowOf(ExplorerContextRow)),
      'project': metaRight(
        tester,
        find.ancestor(
          of: find.text(_long),
          matching: find.byType(ExplorerProjectRow),
        ),
      ),
      'session': metaRight(tester, sessionRow('Running session')),
    };
    final column = edges['session']!;
    for (final entry in edges.entries) {
      expect(
        entry.value,
        moreOrLessEquals(column, epsilon: 0.5),
        reason: '${entry.key} ends at ${entry.value}, sessions at $column',
      );
    }
  });

  testWidgets('a session row draws exactly one status glyph', (tester) async {
    await pumpExplorer(tester);

    for (final title in [
      'Running session',
      'Unknown session',
      'Finished session',
      'Unread session',
    ]) {
      expect(statusGlyphsIn(sessionRow(title)), findsOneWidget, reason: title);
    }
  });

  testWidgets('bold is kept for a session that is unread', (tester) async {
    await pumpExplorer(tester);

    FontWeight? weight(String title) =>
        tester.widget<Text>(find.text(title)).style?.fontWeight;
    expect(weight('Unread session'), FontWeight.w600);
    expect(weight('Finished session'), FontWeight.w500);
    expect(weight('Running session'), FontWeight.w500);
  });

  testWidgets('a long project name wins the row from its count', (
    tester,
  ) async {
    await pumpExplorer(tester);

    expect(tester.getSize(find.text(_long)).width, greaterThanOrEqualTo(150));
  });

  testWidgets('rows are flat at rest and fill under the pointer', (
    tester,
  ) async {
    await pumpExplorer(tester);

    for (final row in [
      rowOf(ExplorerEnvironmentRow),
      rowOf(ExplorerContextRow),
      sessionRow('Running session'),
      sessionRow('Finished session'),
    ]) {
      expect(fillsIn(tester, row), isEmpty, reason: '$row is tinted at rest');
    }

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Game dev')));
    await tester.pumpAndSettle();
    expect(fillsIn(tester, rowOf(ExplorerContextRow)), isNotEmpty);
  });
}

String _plain(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';
