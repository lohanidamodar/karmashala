import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/cli_detection/domain/imported_session.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_agent_filter.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/domain/agent_filter.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **Showing one agent's sessions, or two, without losing the rest.**
///
/// The owner runs Claude Code, Codex and Antigravity side by side and asked for
/// the Explorer narrowed to a chosen *set* of them. It is a **filter** and
/// deliberately not a `SectionRuleKind` — the argument is written out in
/// [AgentFilter], and its load-bearing half is asserted here: a section and the
/// filter compose rather than compete, because `assignSections` hands each row
/// to exactly one section and an "agent" section would therefore have taken a
/// red-build Codex row *away* from "Checks failing".
///
/// The rest of the file is about honesty. A filter that hides rows has one way
/// to go badly wrong — a session the user knows they have is not on the list
/// and nothing says why — so every path that could drop a row silently is
/// pinned: a session whose agent the workspace can no longer name is never
/// hidden, imported history is classified rather than exempted, and a project
/// the filter emptied says so where its rows would have been.
void main() {
  const registry = AgentRegistry.builtIn;

  /// A workspace with one session per agent plus an imported Claude Code
  /// conversation — the owner's shape in miniature.
  AppDatabase seed({
    bool withAntigravity = true,
    bool retiredAgent = false,
    bool failed = false,
    String importedCli = AgentIds.claudeCode,
  }) {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(db).insert(
      repository(id: 'r1', projectId: 'p1', name: 'hub', path: r'C:\hub'),
    );
    final agents = AgentInstallationDao(db);
    agents.insert(agentInstallation(id: 'a-claude'));
    agents.insert(agentInstallation(id: 'a-codex', agentId: AgentIds.codex));
    agents.insert(
      agentInstallation(id: 'a-agy', agentId: AgentIds.antigravity),
    );
    final sessions = SessionDao(db);
    final status = failed ? SessionStatus.failed : SessionStatus.running;
    sessions.insert(
      session(
        id: 's-claude',
        title: 'Claude work',
        agentInstallationId: 'a-claude',
        status: status,
      ),
    );
    sessions.insert(
      session(
        id: 's-codex',
        title: 'Codex work',
        agentInstallationId: 'a-codex',
        status: status,
      ),
    );
    if (withAntigravity) {
      sessions.insert(
        session(
          id: 's-agy',
          title: 'Agy work',
          agentInstallationId: 'a-agy',
          status: SessionStatus.running,
        ),
      );
    }
    if (retiredAgent) {
      // The shape `AgentInstallationsController` documents and deliberately
      // leaves alone: "a stored row for a descriptor the registry no longer
      // carries was never probed, so nothing here is evidence about it". The
      // installation survives, its `agent_kind` names nothing the menu can
      // offer, and its sessions are therefore unclassifiable.
      agents.insert(
        agentInstallation(id: 'a-retired', agentId: 'someRetiredAgent'),
      );
      sessions.insert(
        session(
          id: 's-orphan',
          title: 'Orphan work',
          agentInstallationId: 'a-retired',
          status: SessionStatus.running,
        ),
      );
    }
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i-claude',
        repositoryId: 'r1',
        cli: importedCli,
        externalId: 'ext-1',
        environmentId: 'windows',
        filePath: r'C:\store\ext-1.jsonl',
        storeHome: r'C:\store',
        isSubagent: false,
        preview: 'Imported history',
        title: 'Imported history',
        createdAt: testTime,
      ),
    );
    return db;
  }

  ProviderContainer mount(AppDatabase db) {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        // The two stand-ins an *expanded* panel needs, for the reason
        // `explorer_panel_scale_test.dart` gives: a real terminal probe and a
        // real auto-import both keep frames coming, and `pumpAndSettle` on a
        // tree that never stops is a timeout rather than a measurement.
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The titles the Explorer would draw under the seeded project.
  List<String> shown(ProviderContainer container) {
    final visible = container.read(visibleProjectSessionsProvider('p1'));
    return [
      for (final s in visible.sessions.native) s.title,
      for (final s in visible.sessions.imported) s.displayTitle,
    ]..sort();
  }

  int hiddenIn(ProviderContainer container) =>
      container.read(visibleProjectSessionsProvider('p1')).hidden;

  void narrowTo(ProviderContainer container, Set<String> agents) => container
      .read(settingsControllerProvider.notifier)
      .setExplorerAgentFilter(agents);

  group('the filter itself', () {
    test('empty means every agent, not none', () {
      expect(AgentFilter.all.isUnfiltered, isTrue);
      expect(AgentFilter.all.allows(AgentIds.codex), isTrue);
      expect(AgentFilter.all.allows(null), isTrue);
    });

    test('ticking builds a set, and unticking the last one clears it', () {
      final one = AgentFilter.all.toggled(AgentIds.codex);
      expect(one.agentIds, {AgentIds.codex});
      expect(one.allows(AgentIds.claudeCode), isFalse);

      final two = one.toggled(AgentIds.claudeCode);
      expect(two.agentIds, {AgentIds.codex, AgentIds.claudeCode});
      expect(two.allows(AgentIds.antigravity), isFalse);
      expect(
        two.allows(AgentIds.codex) && two.allows(AgentIds.claudeCode),
        isTrue,
        reason: '"two of them only" is the case the request named',
      );

      expect(
        two.toggled(AgentIds.codex).toggled(AgentIds.claudeCode).isUnfiltered,
        isTrue,
        reason:
            'a filter whose natural end state is a blank sidebar is one users '
            'learn to be afraid of',
      );
    });

    test('a session it cannot name is never hidden', () {
      const only = AgentFilter({AgentIds.codex});
      expect(
        only.allows(null),
        isTrue,
        reason:
            'null is "the workspace cannot say", and the menu offers no row '
            'that would give such a session back',
      );
    });

    test('says which agents are on the list and which are off it', () {
      expect(agentFilterTooltip(AgentFilter.all, registry), 'Filter sessions');
      expect(
        agentFilterTooltip(const AgentFilter({AgentIds.codex}), registry),
        'Showing Codex CLI only — Claude Code and Antigravity hidden',
      );
      expect(
        agentFilterTooltip(
          const AgentFilter({AgentIds.codex, AgentIds.claudeCode}),
          registry,
        ),
        'Showing Claude Code and Codex CLI only — Antigravity hidden',
      );
    });
  });

  group("a project's rows", () {
    test('are everything until somebody narrows them', () {
      final db = seed();
      addTearDown(db.close);
      final container = mount(db);

      expect(shown(container), [
        'Agy work',
        'Claude work',
        'Codex work',
        'Imported history',
      ]);
      expect(hiddenIn(container), 0);
    });

    test('narrow to one agent, and say how many that cost', () {
      final db = seed();
      addTearDown(db.close);
      final container = mount(db);
      narrowTo(container, {AgentIds.codex});

      expect(shown(container), ['Codex work']);
      expect(
        hiddenIn(container),
        3,
        reason:
            'the count is said where the rows are missing, which is the one '
            'place it is free to say it',
      );
    });

    test('narrow to two, which is the case a section cannot answer', () {
      final db = seed();
      addTearDown(db.close);
      final container = mount(db);
      narrowTo(container, {AgentIds.codex, AgentIds.antigravity});

      expect(shown(container), ['Agy work', 'Codex work']);
    });

    test('classify imported history rather than exempting it', () {
      final db = seed();
      addTearDown(db.close);
      final container = mount(db);
      narrowTo(container, {AgentIds.claudeCode});

      expect(
        shown(container),
        ['Claude work', 'Imported history'],
        reason:
            'an imported conversation names its CLI in ImportedSession.cli, so '
            'it is filtered like any other row',
      );

      narrowTo(container, {AgentIds.codex});
      expect(
        shown(container),
        ['Codex work'],
        reason: 'and hidden like any other row when it is not the one asked for',
      );
    });

    test('never hide a session whose agent the workspace cannot name', () {
      final db = seed(retiredAgent: true);
      addTearDown(db.close);
      final container = mount(db);
      narrowTo(container, {AgentIds.codex});

      expect(
        shown(container),
        ['Codex work', 'Orphan work'],
        reason:
            'no menu row could bring this session back, so no filter may take '
            'it away',
      );
    });

    test('never hide an agent the registry has never heard of', () {
      final db = seed(importedCli: 'someOtherCli');
      addTearDown(db.close);
      final container = mount(db);
      narrowTo(container, {AgentIds.codex});

      expect(shown(container), ['Codex work', 'Imported history']);
    });
  });

  group('a section and the filter', () {
    List<String> idsIn(ProviderContainer container, String sectionId) => [
      for (final facts
          in container.read(explorerSectionMembersProvider(sectionId)))
        facts.id,
    ];

    test('intersect rather than compete', () async {
      final db = seed(withAntigravity: false, failed: true);
      addTearDown(db.close);
      final container = mount(db);
      container
          .read(explorerSectionsProvider.notifier)
          .setCollapsed('section-ended-in-failure', false);
      await container.pump();

      expect(idsIn(container, 'section-ended-in-failure')..sort(), [
        's-claude',
        's-codex',
      ]);

      narrowTo(container, {AgentIds.codex});
      await container.pump();
      expect(
        idsIn(container, 'section-ended-in-failure'),
        ['s-codex'],
        reason:
            'the section decides which rows belong together; the filter '
            'decides which of those you are looking at',
      );
    });

    test('and a section the filter emptied folds away like any other', () async {
      final db = seed(withAntigravity: false, failed: true);
      addTearDown(db.close);
      final container = mount(db);
      await container.pump();

      expect(
        container.read(explorerSectionLayoutProvider).shown.map((s) => s.name),
        contains('Ended in failure'),
      );

      narrowTo(container, {AgentIds.antigravity});
      await container.pump();
      final layout = container.read(explorerSectionLayoutProvider);
      expect(
        layout.shown.map((s) => s.name),
        isNot(contains('Ended in failure')),
      );
      expect(
        layout.hidden,
        4,
        reason:
            'one funnel, one count: a section emptied by the agent filter is '
            'held back by the same control and reported by the same number',
      );
    });
  });

  group('the header', () {
    Future<ProviderContainer> pump(WidgetTester tester, AppDatabase db) async {
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = mount(db);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('narrows the tree from the funnel, and says so', (
      tester,
    ) async {
      final db = seed();
      addTearDown(db.close);
      final container = await pump(tester, db);

      expect(find.text('Codex work'), findsOneWidget);
      expect(find.text('Claude work'), findsOneWidget);

      await tester.tap(find.byIcon(AppIcons.funnel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Codex CLI'));
      await tester.pumpAndSettle();

      expect(find.text('Codex work'), findsOneWidget);
      expect(
        find.text('Claude work'),
        findsNothing,
        reason: 'that is what "Codex only" has to mean',
      );
      // **The whole point of the row.** A shorter list and a filtered list look
      // identical, and this is the sentence that tells them apart.
      expect(find.text('3 more hidden by the agent filter.'), findsOneWidget);
      expect(
        container.read(settingsControllerProvider).explorerAgentFilter,
        [AgentIds.codex],
        reason: 'the choice is a setting, so it survives a restart',
      );
    });

    testWidgets('fills its glyph and names what is off the list', (
      tester,
    ) async {
      final db = seed();
      addTearDown(db.close);
      final container = await pump(tester, db);
      // Off, so the tooltip is about the agents alone — the two clauses are
      // asserted separately rather than as one brittle sentence.
      container.read(settingsControllerProvider.notifier).setHideEmptySections(
        false,
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(AppIcons.funnelFill), findsNothing);

      narrowTo(container, {AgentIds.codex});
      await tester.pumpAndSettle();

      expect(
        find.byIcon(AppIcons.funnelFill),
        findsOneWidget,
        reason:
            'a narrowing the user chose has to be legible before anyone hovers '
            '— and by shape, not by colour',
      );
      expect(
        find.byTooltip(
          'Showing Codex CLI only — Claude Code and Antigravity hidden',
        ),
        findsOneWidget,
      );
    });

    testWidgets('never says "no sessions yet" over sessions it hid', (
      tester,
    ) async {
      final db = seed(withAntigravity: false);
      addTearDown(db.close);
      final container = await pump(tester, db);

      narrowTo(container, {AgentIds.antigravity});
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No sessions yet'),
        findsNothing,
        reason:
            'that sentence invites the user to start work they already have',
      );
      expect(
        find.text('3 sessions hidden by the agent filter.'),
        findsOneWidget,
      );
    });
  });
}
