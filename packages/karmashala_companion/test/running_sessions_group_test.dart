/// What is running, pinned on top of every list the phone draws.
///
/// The group is a **view of the snapshot**, and these tests are mostly about
/// that: membership comes from the rows the host sent and changes only when
/// the next snapshot changes it, the header carries the reading's age beside
/// its count, and a search narrows the group exactly as it narrows the list
/// under it. The rest holds the two shapes it takes — lifted out of a list of
/// sessions, pinned above a list of projects — so that no screen ever shows
/// one session twice.
library;

import 'package:karmashala_core/util.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';
import 'package:karmashala_companion/providers.dart';

final _now = DateTime.utc(2026, 9, 10, 12);

/// A clock whose **first** reading is the instant the snapshot is stamped at
/// and whose every later reading is [after].
///
/// That gap is the whole point: if the header's age came from the frame it is
/// drawn in rather than from the snapshot's own stamp, it would read "just
/// now" here no matter how old the reading was.
class _SteppingClock implements Clock {
  _SteppingClock({required this.stamped, required this.after});

  final DateTime stamped;
  final DateTime after;
  bool _first = true;

  @override
  DateTime nowUtc() {
    if (!_first) return after;
    _first = false;
    return stamped;
  }
}

List<Override> _at(Clock clock) => [companionClockProvider.overrideWithValue(clock)];

/// Two projects, two of whose four sessions the host says are working.
FakeCompanionGateway _twoRunning() => FakeCompanionGateway.paired(
  sessions: [
    summary(
      's1',
      title: 'Fix the login flow',
      project: 'popupbits',
      projectId: 'p1',
      projectPath: '/w/popupbits',
      status: CompanionSessionStatus.working,
    ),
    summary(
      's2',
      title: 'Port the parser',
      project: 'popupbits',
      projectId: 'p1',
      projectPath: '/w/popupbits',
      status: CompanionSessionStatus.idle,
    ),
    summary(
      's3',
      title: 'Ship the release',
      project: 'karmashala',
      projectId: 'p2',
      projectPath: '/w/karmashala',
      status: CompanionSessionStatus.working,
    ),
    summary(
      's4',
      title: 'Translate the tips',
      project: 'karmashala',
      projectId: 'p2',
      projectPath: '/w/karmashala',
      status: CompanionSessionStatus.idle,
    ),
  ],
);

void main() {
  group('above the projects index', () {
    testWidgets('names its count and the age of the reading behind it', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _twoRunning(),
        home: const SessionListScreen(),
        overrides: _at(
          _SteppingClock(
            stamped: _now.subtract(const Duration(minutes: 4)),
            after: _now,
          ),
        ),
      );

      expect(find.text('RUNNING NOW'), findsOneWidget);
      expect(find.text('2 sessions  ·  4m ago'), findsOneWidget);
      // Both running rows, above the projects — and the projects are still
      // the list.
      expect(find.text('Fix the login flow'), findsOneWidget);
      expect(find.text('Ship the release'), findsOneWidget);
      expect(find.byType(ProjectCard), findsNWidgets(2));
      // Not the idle ones: this level lists projects, not sessions.
      expect(find.text('Port the parser'), findsNothing);
    });

    testWidgets('is absent, not empty, when nothing is running', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary(
            's1',
            project: 'popupbits',
            projectId: 'p1',
            status: CompanionSessionStatus.idle,
          ),
          summary(
            's2',
            project: 'karmashala',
            projectId: 'p2',
            status: CompanionSessionStatus.needsYou,
          ),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('RUNNING NOW'), findsNothing);
      expect(find.byType(SessionCard), findsNothing);
      expect(find.byType(ProjectCard), findsNWidgets(2));
    });

    testWidgets('a session that stops leaves on the next snapshot, and only '
        'then', (tester) async {
      final gateway = _twoRunning();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      expect(find.text('2 sessions  ·  just now'), findsOneWidget);

      gateway.setSessions([
        summary(
          's1',
          title: 'Fix the login flow',
          project: 'popupbits',
          projectId: 'p1',
          status: CompanionSessionStatus.idle,
        ),
        summary(
          's3',
          title: 'Ship the release',
          project: 'karmashala',
          projectId: 'p2',
          status: CompanionSessionStatus.working,
        ),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('1 session  ·  just now'), findsOneWidget);
      expect(find.text('Ship the release'), findsOneWidget);
      expect(find.text('Fix the login flow'), findsNothing);
    });

    testWidgets('names each row’s project, which nothing else on this level '
        'does', (tester) async {
      await pumpPhone(
        tester,
        gateway: _twoRunning(),
        home: const SessionListScreen(),
      );

      // Twice: once as the project row, once placing the pinned session.
      expect(find.text('popupbits'), findsNWidgets(2));
      expect(find.text('karmashala'), findsNWidgets(2));
    });

    testWidgets('opens a pinned session the way its own project would', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _twoRunning(),
        home: const SessionListScreen(),
      );

      await tester.tap(find.text('Ship the release'));
      await tester.pumpAndSettle();

      expect(find.byType(SessionViewScreen), findsOneWidget);
    });

    testWidgets('a search narrows the group as well as the list', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _twoRunning(),
        home: const SessionListScreen(),
      );

      await tester.enterText(find.byType(TextField).first, 'karmashala');
      await tester.pump();

      expect(find.text('1 session  ·  just now'), findsOneWidget);
      expect(find.text('Ship the release'), findsOneWidget);
      expect(find.text('Fix the login flow'), findsNothing);
      expect(find.byType(ProjectCard), findsOneWidget);
    });

    testWidgets('a search that leaves nothing running takes the group with it',
        (tester) async {
      await pumpPhone(
        tester,
        gateway: _twoRunning(),
        home: const SessionListScreen(),
      );

      // Matches only an idle session, so its project stays and the group goes.
      await tester.enterText(find.byType(TextField).first, 'parser');
      await tester.pump();

      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.text('RUNNING NOW'), findsNothing);
    });
  });

  group('inside one project', () {
    testWidgets('the running sessions are lifted, never drawn twice', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _twoRunning(),
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );

      expect(find.text('RUNNING NOW'), findsOneWidget);
      expect(find.text('1 session  ·  just now'), findsOneWidget);
      // Two sessions in this project, two cards on the screen: one in the
      // group, one in the list below it.
      expect(find.byType(SessionCard), findsNWidgets(2));
      expect(find.text('Fix the login flow'), findsOneWidget);
      expect(find.text('Port the parser'), findsOneWidget);
      // The pinned row does not repeat the app bar's project name.
      expect(find.text('popupbits'), findsOneWidget);
    });

    testWidgets('is absent when this project has nothing running', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(
          sessions: [
            summary(
              's1',
              project: 'popupbits',
              projectId: 'p1',
              status: CompanionSessionStatus.idle,
            ),
          ],
        ),
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );

      expect(find.text('RUNNING NOW'), findsNothing);
      expect(find.byType(SessionCard), findsOneWidget);
    });
  });

  group('the partition itself', () {
    test('keeps the host’s order inside each part, and sorts neither', () {
      final sessions = [
        summary('z', status: CompanionSessionStatus.idle),
        summary('a', status: CompanionSessionStatus.working),
        summary('m', status: CompanionSessionStatus.idle),
        summary('b', status: CompanionSessionStatus.working),
      ];

      final split = partitionByRunning(sessions);

      expect(split.running.map((s) => s.id), ['a', 'b']);
      expect(split.rest.map((s) => s.id), ['z', 'm']);
    });

    test('a status the host could not name is not a claim that it is running',
        () {
      final split = partitionByRunning([
        summary('u', status: CompanionSessionStatus.unknown),
        summary('f', status: CompanionSessionStatus.failed),
        summary('n', status: CompanionSessionStatus.needsYou),
      ]);

      expect(split.running, isEmpty);
      expect(split.rest, hasLength(3));
    });
  });
}
