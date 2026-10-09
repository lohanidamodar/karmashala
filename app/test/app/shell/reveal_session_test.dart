import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_routes.dart';
import 'package:karmashala/src/app/shell/reveal_session.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **A notification opens where the session is** (round 81): its tab when it
/// has one, else the Agent dashboard with it peeked — never an empty screen,
/// and never a tab of its own.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows
      ..insert(session(id: 's1', title: 'Fix login redirect'))
      ..insert(session(id: 's2', title: 'Chatted in the peek'))
      ..insert(session(id: 's3', title: 'Archived'));
    db.server.sessionRows.markArchived('s3', testTime);
  });

  Future<ProviderContainer> launch(WidgetTester tester) async {
    final prefs = Directory.systemTemp.createTempSync('ks-reveal');
    addTearDown(() => prefs.deleteSync(recursive: true));
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        overviewPrefsDirectoryProvider.overrideWithValue(() async => prefs),
      ],
    );
    addTearDown(container.dispose);
    // The dashboard's peek lives while the dashboard is built; held here so
    // what a reveal peeked can be read back.
    container.listen(overviewFocusProvider, (_, _) {});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold()),
      ),
    );
    return container;
  }

  TerminalSessionsController terminals(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  String? activeTab(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider).activeTabId;

  String? overviewTab(ProviderContainer container) =>
      terminals(container).tabIdOfPane(kOverviewPaneId);

  testWidgets('a session with a tab: that tab comes forward', (tester) async {
    final container = await launch(tester);
    final chat = terminals(container).openChatTab('s1');
    terminals(container).openSettingsTab();
    expect(activeTab(container), isNot(chat));

    final went = revealSession(container, openId: 's1');
    await tester.pump();

    expect(went, SessionReveal.tab);
    expect(activeTab(container), chat);
    expect(container.read(selectedSessionIdProvider), 's1');
    expect(overviewTab(container), isNull);
  });

  testWidgets('one without a tab: the dashboard, with it peeked', (
    tester,
  ) async {
    final container = await launch(tester);
    terminals(container).openSettingsTab();

    final went = revealSession(container, openId: 's2');
    await tester.pump();
    await tester.pump();

    expect(went, SessionReveal.dashboard);
    expect(activeTab(container), overviewTab(container));
    expect(container.read(overviewFocusProvider).peeked, 's2');
    // Revealing opens no tab of the session's own.
    expect(container.read(paneSessionsProvider).panesOf('s2'), isEmpty);
    expect(container.read(selectedSessionIdProvider), isNull);
  });

  testWidgets('an archived or deleted one: a word, and the dashboard', (
    tester,
  ) async {
    final container = await launch(tester);
    for (final id in ['s3', 'never-was']) {
      final before = container.read(sessionRevealNoticeProvider)?.seq ?? 0;

      final went = revealSession(container, openId: id);
      await tester.pump();

      expect(went, SessionReveal.gone, reason: id);
      expect(container.read(sessionRevealNoticeProvider)?.seq, before + 1);
      expect(activeTab(container), overviewTab(container));
      expect(activeTab(container), isNotNull);
    }
  });

  testWidgets('the phone: its Dashboard tab and the peek page', (tester) async {
    final container = await launch(tester);
    final routes = _Routes();
    container.read(phoneShellRouterProvider).attach(routes);
    // A tab in the workbench is not where a phone looks.
    terminals(container).openChatTab('s1');

    final went = revealSession(container, openId: 's1');
    await tester.pump();
    await tester.pump();

    expect(went, SessionReveal.dashboard);
    expect(routes.shown, ['dashboard']);
    expect(container.read(overviewFocusProvider).peeked, 's1');
    expect(container.read(phoneWorkbenchProvider), isFalse);

    revealSession(container, openId: 'never-was');
    expect(routes.shown, ['dashboard', 'dashboard']);
  });

  testWidgets('the tray, the Inbox and Ctrl+Shift+J reveal through it', (
    tester,
  ) async {
    final container = await launch(tester);
    container.listen(attentionInboxProvider, (_, _) {});
    await tester.pump();

    // Every one of them asks the server to open the item, which tells this
    // window which session to show.
    server.attention.openWanted('s2');
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(activeTab(container), overviewTab(container));
    expect(container.read(overviewFocusProvider).peeked, 's2');
  });

  testWidgets('activating a tab that is gone lands on the dashboard', (
    tester,
  ) async {
    final container = await launch(tester);
    final settings = terminals(container).openSettingsTab();
    terminals(container).closeTab(settings);

    expect(terminals(container).activateTab(settings), isFalse);
    expect(activeTab(container), isNot(settings));
  });
}

class _Routes implements PhoneShellRoutes {
  final shown = <String>[];

  @override
  void showDashboard() => shown.add('dashboard');

  @override
  void showInbox() => shown.add('inbox');

  @override
  void showMore(PhoneMoreEntry entry) => shown.add('more:${entry.name}');

  @override
  void showProjects() => shown.add('projects');

  @override
  void showWorkbench() => shown.add('workbench');
}
