/// The phone's first tab after Loop 82's rebuild: **projects**, each opening
/// its own sessions.
///
/// The bug these tests exist to hold is the one the owner reported by hand —
/// "can't understand the projects and sessions distinction, and navigating
/// between projects". So: a project row must not be mistakable for a session
/// row (they are not even on the same screen), moving between projects must
/// not mean scrolling through sessions, and every state the screen can be in
/// must say something a user can act on.
library;

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';

import 'companion_test_support.dart';

/// A paired, connected gateway whose session stream fails — the only state the
/// scripted fake cannot reach on its own.
class _FailingGateway extends FakeCompanionGateway {
  _FailingGateway()
    : super(
        pairing: CompanionPairing(
          capabilities: CapabilitySet.all,
          hostName: 'Desktop',
        ),
        link: CompanionLinkState.connected,
      );

  @override
  Stream<List<CompanionSessionSummary>> watchSessions() => Stream.error(
    const GatewayException('The desktop refused to list its sessions.'),
  );
}

void main() {
  group('the projects index', () {
    testWidgets('lists projects, not sessions, when there is more than one', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          // Idle on purpose: a running session is pinned above the index
          // (running_sessions_group.dart), and this test is about the
          // project rows.
          summary(
            's1',
            title: 'Fix the login flow',
            project: 'popupbits',
            projectId: 'p1',
            projectPath: '/w/popupbits',
            status: CompanionSessionStatus.idle,
          ),
          summary(
            's2',
            project: 'popupbits',
            projectId: 'p1',
            status: CompanionSessionStatus.idle,
          ),
          summary(
            's3',
            title: 'Port the parser',
            project: 'karmashala',
            projectId: 'p2',
            projectPath: '/w/karmashala',
            status: CompanionSessionStatus.idle,
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      // Two containers, named and counted…
      expect(find.byType(ProjectCard), findsNWidgets(2));
      expect(find.text('popupbits'), findsOneWidget);
      expect(find.text('karmashala'), findsOneWidget);
      expect(find.text('2 sessions'), findsOneWidget);
      expect(find.text('1 session'), findsOneWidget);
      expect(find.text('/w/popupbits'), findsOneWidget);

      // …and not one session in sight: the level below lives on its own
      // screen, which is the whole point of the rebuild.
      expect(find.byType(SessionCard), findsNothing);
      expect(find.text('Fix the login flow'), findsNothing);
    });

    testWidgets('shows the environment tag on a project row when present', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary(
            's1',
            project: 'wsl-app',
            projectId: 'p1',
            environmentBadge: 'WSL · Ubuntu',
          ),
          summary('s2', project: 'local-app', projectId: 'p2'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('WSL · Ubuntu'), findsOneWidget);
    });

    testWidgets('a project row is a 48dp target and says what needs you', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary(
            's1',
            project: 'popupbits',
            projectId: 'p1',
            status: CompanionSessionStatus.needsYou,
            attention: CompanionAttention(
              kind: CompanionAttentionKind.needsYou,
              at: DateTime.now().toUtc(),
            ),
          ),
          summary('s2', project: 'karmashala', projectId: 'p2'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.textContaining('1 needs you'), findsOneWidget);
      for (final size in tester.widgetList<ProjectCard>(
        find.byType(ProjectCard),
      )) {
        expect(size, isNotNull);
      }
      expect(
        tester.getSize(find.byType(ProjectCard).first).height,
        greaterThanOrEqualTo(Touch.target),
      );
    });

    testWidgets('a folder the host cannot find is marked on the project', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary(
            's1',
            project: 'gone',
            projectId: 'p1',
            projectPath: '/w/gone',
            folderMissing: true,
          ),
          summary('s2', project: 'here', projectId: 'p2'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('Folder not found — /w/gone'), findsOneWidget);
    });

    testWidgets('one project skips the index and shows its sessions under a '
        'header', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary('s1', title: 'Fix the login flow'),
          summary('s2', title: 'Write the release notes'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      // The project is still named — a header, not a row to tap.
      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.text('popupbits'), findsOneWidget);
      expect(
        tester.widget<ProjectCard>(find.byType(ProjectCard)).onTap,
        isNull,
      );
      expect(find.byType(SessionCard), findsNWidgets(2));
      expect(find.text('Fix the login flow'), findsOneWidget);
    });
  });

  group('navigating', () {
    testWidgets('a project opens its sessions, and back returns to the index', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          // Idle on purpose: a running session is pinned above the index
          // (running_sessions_group.dart), and this test is about the
          // project rows.
          summary(
            's1',
            title: 'Alpha work',
            project: 'alpha',
            projectId: 'p1',
            status: CompanionSessionStatus.idle,
          ),
          summary(
            's2',
            title: 'Beta work',
            project: 'beta',
            projectId: 'p2',
            status: CompanionSessionStatus.idle,
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectSessionsScreen), findsOneWidget);
      expect(find.text('Alpha work'), findsOneWidget);
      expect(find.text('Beta work'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ProjectSessionsScreen), findsNothing);
      expect(find.byType(ProjectCard), findsNWidgets(2));
    });

    testWidgets('the project screen switches projects without going back', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          // Idle on purpose: a running session is pinned above the index
          // (running_sessions_group.dart), and this test is about the
          // project rows.
          summary(
            's1',
            title: 'Alpha work',
            project: 'alpha',
            projectId: 'p1',
            status: CompanionSessionStatus.idle,
          ),
          summary(
            's2',
            title: 'Beta work',
            project: 'beta',
            projectId: 'p2',
            status: CompanionSessionStatus.idle,
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );
      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();

      // The title is the switcher: one tap to the list of projects, one to
      // the project. No scrolling past anyone else's sessions.
      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta').last);
      await tester.pumpAndSettle();

      expect(find.text('Beta work'), findsOneWidget);
      expect(find.text('Alpha work'), findsNothing);
      // Still one push deep: back goes to the index, not to alpha.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ProjectCard), findsNWidgets(2));
    });

    testWidgets('tapping a session opens its transcript', (tester) async {
      final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      await tester.tap(find.text('Session s1'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionViewScreen), findsOneWidget);
    });
  });

  group('the four states', () {
    testWidgets('the first frame is a skeleton, not an empty claim', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // No settling pump: the stream has not delivered yet.
      await tester.pumpWidget(
        buildPhoneApp(gateway: gateway, home: const SessionListScreen()),
      );

      expect(find.textContaining('No projects'), findsNothing);
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
      expect(find.byType(InlineSpinner), findsNothing);
    });

    testWidgets('a connected host with nothing on it says what to do next', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('No projects yet'), findsOneWidget);
      expect(find.textContaining('start a session'), findsOneWidget);
    });

    testWidgets('an unreachable host is a different empty state, with a '
        'retry that actually retries', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        link: CompanionLinkState.disconnected,
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('Nothing to show yet'), findsOneWidget);
      expect(find.textContaining('cannot reach Desktop'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(gateway.reconnectRequests, 1);
    });

    testWidgets('a failing stream is a sentence, never a Dart type', (
      tester,
    ) async {
      final gateway = _FailingGateway();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(
        find.text('The desktop refused to list its sessions.'),
        findsOneWidget,
      );
      expect(find.textContaining('GatewayException'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('robustness', () {
    const longProject =
        'a-project-name-that-is-sixty-characters-long-for-sure-abcdef';
    const longTitle =
        'a session title that is sixty characters long, give or take';

    testWidgets('a 60-character project name and session title truncate '
        'rather than overflow', (tester) async {
      expect(longProject.length, greaterThanOrEqualTo(60));
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary(
            's1',
            title: longTitle,
            project: longProject,
            projectId: 'p1',
            projectPath: '/a/very/long/path/that/goes/on/and/on/and/on/forever',
            branch: 'feature/a-branch-name-nobody-would-ever-type-by-hand-ok',
          ),
          summary('s2', project: 'other', projectId: 'p2'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(longProject));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(longTitle), findsOneWidget);
    });

    testWidgets('dark mode renders both levels', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          // Idle on purpose: a running session is pinned above the index
          // (running_sessions_group.dart), and this test is about the
          // project rows.
          summary(
            's1',
            title: 'Alpha work',
            project: 'alpha',
            projectId: 'p1',
            status: CompanionSessionStatus.idle,
          ),
          summary(
            's2',
            title: 'Beta work',
            project: 'beta',
            projectId: 'p2',
            status: CompanionSessionStatus.idle,
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
        brightness: Brightness.dark,
      );
      expect(find.byType(ProjectCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('200% text scale grows the rows instead of clipping them', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary(
            's1',
            title: 'Fix the login flow',
            project: 'popupbits',
            projectId: 'p1',
            projectPath: '/w/popupbits',
            status: CompanionSessionStatus.needsYou,
          ),
          summary('s2', project: 'other', projectId: 'p2'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
        textScale: 2.0,
      );
      expect(tester.takeException(), isNull);
      final row = tester.getSize(find.byType(ProjectCard).first).height;
      expect(row, greaterThan(Touch.target));

      await tester.tap(find.text('popupbits'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(AppIcons.warningCircle), findsWidgets);
    });
  });
}
