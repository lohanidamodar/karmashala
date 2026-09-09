/// One project's sessions, on their own screen.
///
/// The screen that makes the hierarchy legible: its app bar *is* the project,
/// so nothing below it has to be read as "a project header" rather than "a
/// session". These tests hold that, the way sideways (the switcher), and every
/// state the screen can be in.
library;

import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/presentation/project_sessions_screen.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

class _MetadataGateway extends FakeCompanionGateway {
  _MetadataGateway(this.projects)
    : super(
        pairing: CompanionPairing(
          capabilities: CapabilitySet.all,
          hostName: 'Desktop',
        ),
        link: CompanionLinkState.connected,
      );

  final List<RemoteWorkspaceProject> projects;

  @override
  Future<List<RemoteWorkspaceProject>> listProjects() async => projects;
}

void main() {
  testWidgets('names the project in the app bar and lists only its sessions', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Alpha work',
          project: 'alpha',
          projectId: 'p1',
          projectPath: '/w/alpha',
        ),
        summary('s2', title: 'Beta work', project: 'beta', projectId: 'p2'),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );

    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('alpha')),
      findsOneWidget,
    );
    expect(find.byType(SessionCard), findsOneWidget);
    expect(find.text('Alpha work'), findsOneWidget);
    expect(find.text('Beta work'), findsNothing);
    // The facts the app bar cannot carry.
    expect(find.text('1 session'), findsOneWidget);
    expect(find.text('/w/alpha'), findsOneWidget);
  });

  testWidgets('shows environment tag in facts when present', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          project: 'alpha',
          projectId: 'p1',
          projectPath: '/w/alpha',
          environmentBadge: 'WSL · Ubuntu',
        ),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );

    expect(find.text('WSL · Ubuntu'), findsOneWidget);
  });

  testWidgets('a session row is at least a 48dp target', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [summary('s1', project: 'alpha', projectId: 'p1')],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );

    expect(
      tester.getSize(find.byType(SessionCard).first).height,
      greaterThanOrEqualTo(Touch.target),
    );
  });

  testWidgets('the switcher lists every project with its counts', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary('s1', project: 'alpha', projectId: 'p1'),
        summary('s2', project: 'beta', projectId: 'p2'),
        summary(
          's3',
          project: 'beta',
          projectId: 'p2',
          attention: CompanionAttention(
            kind: CompanionAttentionKind.needsYou,
            at: DateTime.now().toUtc(),
          ),
        ),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );

    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();

    expect(find.text('Projects on this desktop'), findsOneWidget);
    expect(find.text('2 sessions  ·  1 needs you'), findsOneWidget);

    await tester.tap(find.text('beta').last);
    await tester.pumpAndSettle();
    expect(find.byType(SessionCard), findsNWidgets(2));
  });

  testWidgets('a single-project host gets no switcher — there is nowhere to '
      'switch to', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [summary('s1', project: 'alpha', projectId: 'p1')],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );

    await tester.tap(find.text('alpha'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Projects on this desktop'), findsNothing);
  });

  testWidgets('metadata-only projects can switch between empty projects', (
    tester,
  ) async {
    final gateway = _MetadataGateway(const [
      RemoteWorkspaceProject(
        projectId: 'p1',
        name: 'Empty alpha',
        path: r'C:\alpha',
      ),
      RemoteWorkspaceProject(
        projectId: 'p2',
        name: 'Empty beta',
        path: r'C:\beta',
      ),
    ]);
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );

    await tester.tap(find.text('Empty alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Empty beta'), findsOneWidget);

    await tester.tap(find.text('Empty beta').last);
    await tester.pumpAndSettle();
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Empty beta')),
      findsOneWidget,
    );
  });

  testWidgets('a project the host stops listing says so, with a way out', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [summary('s1', project: 'alpha', projectId: 'p1')],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );
    expect(find.byType(SessionCard), findsOneWidget);

    gateway.setSessions(const []);
    await tester.pump();

    expect(find.text('This project is gone'), findsOneWidget);
    expect(find.text('Back to projects'), findsOneWidget);
    expect(find.byType(SessionCard), findsNothing);
  });

  testWidgets('the first frame is a skeleton, not a false "gone"', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [summary('s1', project: 'alpha', projectId: 'p1')],
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      buildPhoneApp(
        gateway: gateway,
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      ),
    );

    expect(find.text('This project is gone'), findsNothing);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
  });

  testWidgets('a 60-character project name ellipsises in the app bar', (
    tester,
  ) async {
    const long = 'a-project-name-that-is-sixty-characters-long-for-sure-abcdef';
    final gateway = FakeCompanionGateway.paired(
      sessions: [summary('s1', project: long, projectId: 'p1')],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(long), findsOneWidget);
  });

  testWidgets('200% text neither clips the app bar nor overflows a row', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Fix the login flow',
          project: 'alpha',
          projectId: 'p1',
          branch: 'fix/login',
          whereabouts: 'last seen 2h ago',
          status: CompanionSessionStatus.needsYou,
        ),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
      textScale: 2.0,
    );

    expect(tester.takeException(), isNull);
    final bar = tester.getSize(find.byType(AppBar));
    expect(
      bar.height,
      greaterThan(Touch.appBar),
      reason: 'the bar grows with the text rather than clipping it',
    );
  });

  testWidgets('dark mode renders the project screen', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [summary('s1', project: 'alpha', projectId: 'p1')],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
      brightness: Brightness.dark,
    );
    expect(find.byType(SessionCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
