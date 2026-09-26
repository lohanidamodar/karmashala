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
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';

/// **Two visible levels and one right-hand column, for every row kind.**
///
/// The owner's screenshot of the Explorer had five levels — machine,
/// `PROJECTS`, context, project, session — each stepped in by a different
/// amount, with counts, `+` and ages ending in different columns. A context is
/// a header over its projects now, so a project stands at depth zero and only
/// its sessions step in. Measured on the real panel, not on the kit widgets.
const _width = 360.0;
const _long = 'popupbits-ai-workspace-with-a-long-name';
const _path = '/Users/me/Documents/projects/popupbits-ai-workspace';

class _OneLineProjects extends SettingsController {
  @override
  Settings build() => const Settings(explorerProjectDetails: false);
}

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
  AppDatabase seeded(FakeDataServer server) {
    final db = AppDatabase.memory();
    server.mirrorInto(db);
    ExecutionEnvironmentDao(db).upsert(posixEnv());
    server.workspaceRows.insert(
      Workspace(id: 'w1', name: 'Game dev', createdAt: testTime),
    );
    server.projectRows.insert(
      project(id: 'p1', name: _long, path: _path, workspaceId: 'w1'),
    );
    server.projectRows.insert(
      project(id: 'p2', name: 'Loose', path: '/srv/p2'),
    );
    server.repositoryRows.insert(
      repository(id: 'r1', projectId: 'p1', path: _path),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    for (final (id, title, status) in [
      ('s-run', 'Running session', SessionStatus.running),
      ('s-unk', 'Unknown session', SessionStatus.unknown),
      ('s-done', 'Finished session', SessionStatus.completed),
      ('s-unread', 'Unread session', SessionStatus.completed),
    ]) {
      mirroredServer(db).sessionRows.insert(session(id: id, title: title, status: status));
    }
    return db;
  }

  Future<void> pumpExplorer(
    WidgetTester tester, {
    double width = _width,
    bool details = true,
  }) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final server = FakeDataServer();
    final db = seeded(server);
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        // A second pump in one test is a second scope, not new overrides.
        key: UniqueKey(),
        overrides: [
          await server.override(),
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
          if (!details)
            settingsControllerProvider.overrideWith(_OneLineProjects.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.macOS),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
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
    // Unread: a finished turn nobody has seen.
    AppIcons.circleFill,
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

  testWidgets('a project starts at depth zero, under a header that indents '
      'nothing', (tester) async {
    await pumpExplorer(tester);

    final header = centreX(
      tester,
      chevronIn(rowOf(ExplorerContextHeader).first),
    );
    final project = centreX(
      tester,
      chevronIn(
        find.ancestor(
          of: find.text(_long),
          matching: find.byType(ExplorerProjectRow),
        ),
      ),
    );
    final loose = centreX(
      tester,
      chevronIn(
        find.ancestor(
          of: find.text('Loose'),
          matching: find.byType(ExplorerProjectRow),
        ),
      ),
    );
    expect(project, moreOrLessEquals(header, epsilon: 0.5));
    expect(loose, moreOrLessEquals(header, epsilon: 0.5));
    expect(
      header,
      moreOrLessEquals(
        ExplorerRow.contentStartOf(UiDensity.pointer) +
            ExplorerRow.disclosureSlot / 2,
        epsilon: 0.5,
      ),
      reason: 'depth zero: the first caret column from the pane\'s edge',
    );
    const step = ExplorerRow.indent;

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
      'header': metaRight(tester, rowOf(ExplorerContextHeader).first),
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

  Finder projectRow() => find.ancestor(
    of: find.text(_long),
    matching: find.byType(ExplorerProjectRow),
  );

  testWidgets('a project says where it is and what is going on, at rest', (
    tester,
  ) async {
    await pumpExplorer(tester, width: 520);

    final row = projectRow();
    final path = find.descendant(
      of: row,
      matching: find.textContaining('popupbits-ai-workspace'),
    );
    // The name, and under it the path with its last folder whole.
    expect(path, findsNWidgets(2));
    final line = tester.widgetList<Text>(path).last.data!;
    expect(line, endsWith('/popupbits-ai-workspace'));
    expect(line, isNot(contains('/Users/me')), reason: 'home is written ~');
    // Words, not a bare number with its meaning in a tooltip.
    expect(
      find.descendant(of: row, matching: find.text('4 sessions')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byTooltip('1 session is running'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byTooltip('1 needs you')),
      findsOneWidget,
    );
    // A header's count is a bare number: its label says what is counted.
    expect(
      find.descendant(
        of: rowOf(ExplorerContextHeader),
        matching: find.byTooltip('1 project'),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('the second line hangs at the name and leaves the right-hand '
      'column where it was', (tester) async {
    await pumpExplorer(tester);
    final row = projectRow();
    final name = tester.getTopLeft(find.text(_long));
    final path = tester.getTopLeft(
      find.descendant(
        of: row,
        matching: find.textContaining('/popupbits-ai-workspace'),
      ),
    );
    expect(path.dx, moreOrLessEquals(name.dx, epsilon: 0.5));
    expect(path.dy, greaterThan(name.dy));

    // A session's own second line hangs one step further in, like its glyph.
    final title = tester.getTopLeft(find.text('Running session')).dx;
    expect(title - name.dx, moreOrLessEquals(ExplorerRow.indent, epsilon: 0.5));

    // Line two's state ends on the edge the counts and ages end on.
    final column = metaRight(tester, sessionRow('Running session'));
    final state = find.descendant(
      of: row,
      matching: find.byType(ProjectStateBadge),
    );
    expect(state, findsWidgets);
    expect(
      tester.getTopRight(state.last).dx,
      moreOrLessEquals(column, epsilon: 0.5),
    );
  });

  testWidgets('at the pane\'s minimum the counts are bare numbers on the same '
      'edge, and the path still keeps its last folder', (tester) async {
    await pumpExplorer(tester, width: 240);
    expect(tester.takeException(), isNull);

    final row = projectRow();
    expect(find.text('4 sessions'), findsNothing);
    expect(find.descendant(of: row, matching: find.text('4')), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(ProjectStateBadge)),
      findsNWidgets(2),
      reason: 'running and needs-you never leave the row',
    );
    final path = tester
        .widgetList<Text>(
          find.descendant(of: row, matching: find.textContaining('…/')),
        )
        .single;
    expect(path.data, '…/popupbits-ai-workspace');
  });

  testWidgets('with project details off a project is one line again', (
    tester,
  ) async {
    await pumpExplorer(tester);
    final detailed = tester.getSize(projectRow()).height;

    await pumpExplorer(tester, details: false);
    expect(tester.getSize(projectRow()).height, lessThan(detailed));
    expect(
      find.descendant(
        of: projectRow(),
        matching: find.textContaining('/popupbits-ai-workspace'),
      ),
      findsNothing,
    );
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

  testWidgets('rows are flat at rest, a header is its band, and both fill '
      'under the pointer', (tester) async {
    await pumpExplorer(tester);
    final scheme = Theme.of(
      tester.element(find.byType(ExplorerContextHeader).first),
    ).colorScheme;

    for (final row in [
      sessionRow('Running session'),
      sessionRow('Finished session'),
    ]) {
      expect(fillsIn(tester, row), isEmpty, reason: '$row is tinted at rest');
    }
    expect(fillsIn(tester, rowOf(ExplorerContextHeader).first), [
      ExplorerRow.bandColor(scheme),
    ], reason: 'a header rests on its band and nothing else');

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('GAME DEV')));
    await tester.pumpAndSettle();
    expect(fillsIn(tester, rowOf(ExplorerContextHeader).first), [
      Color.alphaBlend(
        StateLayers.hover(scheme),
        ExplorerRow.bandColor(scheme),
      ),
    ], reason: 'the hover wash is laid over the band, not in its place');
  });
}

String _plain(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';
