/// Finding a project or a session on the phone.
///
/// The property every test here is really holding is that **nothing crosses
/// the link**: the fakes below never gain a search verb, because the feature
/// is a filter over the snapshot the phone was already holding. What follows
/// from that is the rest of the file — the four fields a row can be found by,
/// the open project surviving a query it does not match, and an empty result
/// that names the snapshot's age rather than implying the desktop was asked.
library;

import 'package:karmashala_core/util.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';
import 'package:karmashala_companion/providers.dart';

/// The instant a screen is rendered at.
final _now = DateTime.utc(2026, 9, 10, 12);

/// A clock a test moves by hand, so the snapshot can be stamped at one instant
/// and read at another — which is the only way an age is ever anything but
/// "just now".
class _MovableClock implements Clock {
  _MovableClock(this.instant);

  DateTime instant;

  @override
  DateTime nowUtc() => instant;
}

List<Override> _at(Clock clock) => [companionClockProvider.overrideWithValue(clock)];

/// Three projects on one desktop, each with work in it.
///
/// Idle throughout: the pinned running group is `running_sessions_group.dart`'s
/// to prove, and a group of session rows above the index would make every
/// `find.text('<project>')` here ambiguous for a reason that is not search.
FakeCompanionGateway _threeProjects() => FakeCompanionGateway.paired(
  sessions: [
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
      title: 'Port the parser',
      project: 'popupbits',
      projectId: 'p1',
      projectPath: '/w/popupbits',
      agentLabel: 'Codex  ·  running',
      status: CompanionSessionStatus.idle,
    ),
    summary(
      's3',
      title: 'Ship the release',
      project: 'karmashala',
      projectId: 'p2',
      projectPath: '/w/karmashala',
      status: CompanionSessionStatus.idle,
    ),
    summary(
      's4',
      title: 'Translate the tips',
      project: 'meronepali',
      projectId: 'p3',
      projectPath: '/src/nepali',
      status: CompanionSessionStatus.idle,
    ),
  ],
);

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pump();
}

void main() {
  group('the field itself', () {
    testWidgets('does not open the keyboard on arrival', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).autofocus, false);
      // The behaviour behind the flag: nothing has claimed the text input, so
      // no phone keyboard has covered the list the user came to read.
      expect(tester.testTextInput.hasAnyClients, false);
    });

    testWidgets('offers no clear button until there is something to clear', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      expect(find.byTooltip('Clear search'), findsNothing);
      await _type(tester, 'karma');
      expect(find.byTooltip('Clear search'), findsOneWidget);
    });

    testWidgets('clearing puts every project back', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      await _type(tester, 'karma');
      expect(find.byType(ProjectCard), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();

      expect(find.byType(ProjectCard), findsNWidgets(3));
      expect(find.byTooltip('Clear search'), findsNothing);
    });
  });

  group('what a query matches', () {
    testWidgets('a project name', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      await _type(tester, 'KARMA');

      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.text('karmashala'), findsOneWidget);
      expect(find.text('popupbits'), findsNothing);
    });

    testWidgets('a project path, which need not be its name', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      await _type(tester, '/src/');

      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.text('meronepali'), findsOneWidget);
    });

    testWidgets('a session title, and the project it narrows to says how many '
        'matched', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      await _type(tester, 'parser');

      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.text('popupbits'), findsOneWidget);
      // Both of popupbits' sessions are still in the snapshot; one of them is
      // what the row is standing for.
      expect(find.text('1 session'), findsOneWidget);
    });

    testWidgets('the agent the host named', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      await _type(tester, 'codex');

      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.text('popupbits'), findsOneWidget);
    });

    testWidgets('naming a project brings all of its sessions, not the ones '
        'whose titles repeat it', (tester) async {
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          summary('s1', title: 'popupbits rename', project: 'popupbits',
              projectId: 'p1', projectPath: '/w/popupbits'),
          summary('s2', title: 'Something else', project: 'popupbits',
              projectId: 'p1', projectPath: '/w/popupbits'),
          summary('s3', project: 'other', projectId: 'p2'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );

      await _type(tester, 'popupbits');

      expect(find.byType(SessionCard), findsNWidgets(2));
    });
  });

  group('on one project’s screen', () {
    testWidgets('the sessions narrow', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );

      expect(find.byType(SessionCard), findsNWidgets(2));
      await _type(tester, 'parser');

      expect(find.byType(SessionCard), findsOneWidget);
      expect(find.text('Port the parser'), findsOneWidget);
      expect(find.text('Fix the login flow'), findsNothing);
    });

    testWidgets('the open project survives a query it does not match', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );

      await _type(tester, 'karmashala');

      // Still this project's screen, still named, still able to be searched
      // again — never "this project is gone", which is what dropping it from
      // the filtered list would have said.
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('popupbits'),
        ),
        findsOneWidget,
      );
      expect(find.text('This project is gone'), findsNothing);
      expect(find.text('No match for "karmashala"'), findsOneWidget);
    });

    testWidgets('an empty result names the fields and the snapshot’s age', (
      tester,
    ) async {
      final clock = _MovableClock(_now.subtract(const Duration(minutes: 7)));
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const ProjectSessionsScreen(projectKey: 'p1'),
        overrides: _at(clock),
      );
      clock.instant = _now;

      await _type(tester, 'nothing at all');

      expect(find.text('No match for "nothing at all"'), findsOneWidget);
      expect(
        find.textContaining('the session titles and agents in popupbits'),
        findsOneWidget,
      );
      expect(find.textContaining('7m ago'), findsOneWidget);
    });
  });

  group('an empty result on the index', () {
    testWidgets('says what was searched, how old the snapshot is, and that the '
        'desktop was not asked', (tester) async {
      final clock = _MovableClock(_now.subtract(const Duration(minutes: 4)));
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
        overrides: _at(clock),
      );
      clock.instant = _now;

      await _type(tester, 'zzz');

      expect(find.byType(ProjectCard), findsNothing);
      expect(find.text('No match for "zzz"'), findsOneWidget);
      expect(
        find.textContaining(
          'project names and paths, and session titles and agents',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('4m ago'), findsOneWidget);
      expect(find.textContaining('Your desktop was not asked'), findsOneWidget);
    });

    testWidgets('offers the way out of the filter', (tester) async {
      await pumpPhone(
        tester,
        gateway: _threeProjects(),
        home: const SessionListScreen(),
      );

      await _type(tester, 'zzz');
      await tester.tap(find.widgetWithText(FilledButton, 'Clear search'));
      await tester.pump();

      expect(find.byType(ProjectCard), findsNWidgets(3));
    });
  });

  group('the matchers themselves', () {
    test('a kept key survives a filter that excludes it, sessions narrowed',
        () {
      final groups = [
        CompanionProjectGroup(
          key: 'p1',
          sessions: [
            summary('a', title: 'Alpha', project: 'one'),
            summary('b', title: 'Beta', project: 'one'),
          ],
        ),
        CompanionProjectGroup(
          key: 'p2',
          sessions: [summary('c', title: 'Alpha again', project: 'two')],
        ),
      ];

      final kept = companionMatchingGroups(groups, 'zzz', keepKey: 'p1');

      expect(kept.map((g) => g.key), ['p1']);
      expect(kept.single.sessions, isEmpty);
      expect(companionMatchingGroups(groups, 'zzz'), isEmpty);
    });

    test('a kept id survives a filter that excludes it', () {
      final sessions = [
        summary('a', title: 'Alpha'),
        summary('b', title: 'Beta'),
      ];

      expect(
        companionMatchingSessions(sessions, 'alpha').map((s) => s.id),
        ['a'],
      );
      expect(
        companionMatchingSessions(sessions, 'alpha', keepId: 'b')
            .map((s) => s.id),
        ['a', 'b'],
      );
    });

    test('an empty query is not a filter', () {
      final sessions = [summary('a'), summary('b')];
      expect(companionMatchingSessions(sessions, ''), same(sessions));
      expect(companionSearchQuery('   '), '');
      expect(companionSearchQuery('  Karma  '), 'karma');
    });

    test('a reading with no recorded time reads unknown, never "just now"', () {
      expect(companionSnapshotAge(null, _now), 'age unknown');
      expect(
        companionSnapshotAge(_now.subtract(const Duration(hours: 2)), _now),
        '2h ago',
      );
    });
  });
}
