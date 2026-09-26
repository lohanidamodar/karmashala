/// Every companion screen at a tablet's width, against CLAUDE.md §6: narrow
/// list content is not stretched across a wide screen.
///
/// The design pass that adopted the shared chrome left this undone — at 600px
/// and up the settings list, the start-session form and both session lists ran
/// their rows the whole width of the viewport, which on an 834px tablet is a
/// session title with 500px of nothing after it and a path the eye has to
/// track back along.
///
/// Each screen is asserted twice: capped at [kTabletSize], and *unconstrained*
/// at [kPhoneSize]. The second half matters as much as the first — the cap is
/// [companionReadableWidth], which is the compact breakpoint itself, so a
/// phone must be exactly as wide as it always was.
library;

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

/// The widest of everything [finder] matches.
double _widest(WidgetTester tester, Finder finder) {
  expect(finder, findsWidgets);
  return tester
      .widgetList(finder)
      .map((widget) => tester.getSize(find.byWidget(widget)).width)
      .reduce((a, b) => a > b ? a : b);
}

/// The content [finder] points at is no wider than a phone, and is centred in
/// what is left over.
void _capped(WidgetTester tester, Finder finder) {
  final width = _widest(tester, finder);
  expect(
    width,
    lessThanOrEqualTo(companionReadableWidth),
    reason: 'CLAUDE.md §6: content is capped, not stretched',
  );
  final box = tester.getRect(find.byWidget(tester.widgetList(finder).first));
  expect(
    box.left,
    moreOrLessEquals(kTabletSize.width - box.right, epsilon: 0.5),
    reason: 'the leftover width is a gutter either side, not one margin',
  );
}

CompanionAttention _needsYou() => CompanionAttention(
  kind: CompanionAttentionKind.needsYou,
  at: DateTime.utc(2026, 9, 2, 12),
);

RemoteWorkspaceProject _project() => const RemoteWorkspaceProject(
  projectId: 'p1',
  name: 'popupbits',
  path: '/w/popupbits',
  checkouts: [
    RemoteCheckoutOption(
      repositoryId: 'r1',
      name: 'app',
      path: '/w/popupbits/app',
      branch: 'main',
      agents: [
        RemoteAgentOption(
          installationId: 'i1',
          agentId: 'roverCli',
          name: 'Rover CLI',
          version: '1.0.0',
          defaultMode: 'ask',
          acceptsOpeningMessage: true,
          permissionModes: [
            RemotePermissionOption(
              mode: 'ask',
              label: 'Ask every time',
              summary: 'Rover CLI is told to use it.',
              selectable: true,
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  final studio = fakeHostId(1);
  final laptop = fakeHostId(2);

  List<CompanionConnection> twoMachines() => [
    CompanionConnection(hostId: studio, name: 'Studio', active: true),
    CompanionConnection(hostId: laptop, name: 'Laptop', active: false),
  ];

  List<CompanionSessionSummary> twoProjects() => [
    summary(
      's1',
      title: 'Wire the gateway',
      project: 'popupbits',
      projectId: 'p1',
    ),
    summary(
      's2',
      title: 'Fix the composer',
      project: 'karmashala',
      projectId: 'p2',
    ),
  ];

  group('the settings list', () {
    testWidgets('keeps a phone measure on a tablet', (tester) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired(connections: twoMachines()),
        home: const CompanionSettingsScreen(),
      );

      _capped(tester, find.byType(ConnectionsSection));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fills a phone', (tester) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(connections: twoMachines()),
        home: const CompanionSettingsScreen(),
      );

      expect(
        _widest(tester, find.byType(ConnectionsSection)),
        kPhoneSize.width - 2 * 16,
        reason: 'a phone pays no gutter — only the list padding it always had',
      );
    });
  });

  group('the start-session form', () {
    testWidgets('keeps a phone measure on a tablet', (tester) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired()..workspace = [_project()],
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rover CLI'), findsOneWidget);
      _capped(tester, find.byType(ListTile));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fills a phone', (tester) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired()..workspace = [_project()],
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(_widest(tester, find.byType(ListTile)), kPhoneSize.width);
    });
  });

  group('the projects list', () {
    testWidgets('keeps a phone measure on a tablet', (tester) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired(sessions: twoProjects()),
        home: const SessionListScreen(),
      );

      expect(find.byType(ProjectCard), findsNWidgets(2));
      _capped(tester, find.byType(ProjectCard));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fills a phone', (tester) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(sessions: twoProjects()),
        home: const SessionListScreen(),
      );

      expect(_widest(tester, find.byType(ProjectCard)), kPhoneSize.width);
    });
  });

  group("one project's sessions", () {
    testWidgets('keep a phone measure on a tablet, rule included', (
      tester,
    ) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired(sessions: twoProjects()),
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );

      _capped(tester, find.byType(SessionCard));
      // The facts strip and its rule take the same gutter, or a tablet draws
      // a full-width line under a 600px column.
      _capped(tester, find.byType(Divider));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fill a phone', (tester) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(sessions: twoProjects()),
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );

      expect(_widest(tester, find.byType(SessionCard)), kPhoneSize.width);
    });
  });

  group('the inbox', () {
    testWidgets('keeps a phone measure on a tablet', (tester) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired(
          sessions: [summary('s1', attention: _needsYou())],
        ),
        home: const InboxScreen(),
      );

      _capped(
        tester,
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(InkWell),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('fills a phone', (tester) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(
          sessions: [summary('s1', attention: _needsYou())],
        ),
        home: const InboxScreen(),
      );

      expect(
        _widest(
          tester,
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(InkWell),
          ),
        ),
        kPhoneSize.width,
      );
    });
  });

  group('the host switcher strip', () {
    testWidgets('paints edge to edge, and aligns its row with the content '
        'below it', (tester) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired(connections: twoMachines()),
        home: const HostSwitcherBar(),
      );

      expect(
        tester.getSize(find.byType(Material).first).width,
        kTabletSize.width,
        reason: 'the strip is chrome: its surface spans the window',
      );
      _capped(
        tester,
        find.descendant(
          of: find.byType(HostSwitcherBar),
          matching: find.byType(Row),
        ),
      );
    });
  });

  group('a session view', () {
    testWidgets('keeps its transcript and composer to a phone measure on a '
        'tablet', (tester) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired(
          sessions: [summary('s1')],
          transcripts: {
            's1': [
              const CompanionChatMessage(
                role: 'agent',
                text: 'A line long enough to want a measure of its own.',
              ),
            ],
          },
        ),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pumpAndSettle();

      _capped(tester, find.byType(CompanionComposer));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fills a phone', (tester) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(
          sessions: [summary('s1')],
          transcripts: {
            's1': [
              const CompanionChatMessage(
                role: 'agent',
                text: 'A line long enough to want a measure of its own.',
              ),
            ],
          },
        ),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pumpAndSettle();

      expect(_widest(tester, find.byType(CompanionComposer)), kPhoneSize.width);
    });
  });

  group('the diagnostics log', () {
    testWidgets('keeps a phone measure on a tablet', (tester) async {
      await pumpTablet(
        tester,
        gateway: FakeCompanionGateway.paired(),
        home: const CompanionLogScreen(),
      );

      _capped(tester, find.byType(Divider));
      expect(tester.takeException(), isNull);
    });
  });
}
