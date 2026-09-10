/// **When a session was last active**, on the tile itself.
///
/// The reading is the host's, not the phone's, and the phone says so in the
/// app's own words: "active 3m ago", from `describeAge`, the helper every
/// other aged claim in this app is rendered with. A session the host sent no
/// time for shows no age at all — an unknown age is not an age of zero
/// (CLAUDE.md §19), and a card that read "active just now" about a session
/// nobody has heard from would be exactly the confident false statement that
/// rule exists to delete.
library;

import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/companion/presentation/companion_session_list.dart';
import 'package:karmashala/src/features/companion/presentation/project_sessions_screen.dart';
import 'package:karmashala/src/features/companion/presentation/session_list_screen.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

final _now = DateTime.utc(2026, 9, 10, 12);

class _FixedClock implements Clock {
  const _FixedClock(this._instant);
  final DateTime _instant;

  @override
  DateTime nowUtc() => _instant;
}

List<Override> get _clock => [
  clockProvider.overrideWithValue(_FixedClock(_now)),
];

void main() {
  testWidgets('a session tile says how long since the host heard from it', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Fix the login flow',
          project: 'popupbits',
          projectId: 'p1',
          status: CompanionSessionStatus.idle,
          lastActivityAt: _now.subtract(const Duration(minutes: 3)),
        ),
        summary(
          's2',
          title: 'Port the parser',
          project: 'popupbits',
          projectId: 'p1',
          status: CompanionSessionStatus.idle,
          lastActivityAt: _now.subtract(const Duration(hours: 26)),
        ),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
      overrides: _clock,
    );

    expect(find.text('active 3m ago'), findsOneWidget);
    expect(find.text('active 1d ago'), findsOneWidget);
  });

  testWidgets('a session the host sent no time for claims no age at all', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Fix the login flow',
          project: 'popupbits',
          projectId: 'p1',
          status: CompanionSessionStatus.idle,
        ),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const ProjectSessionsScreen(projectKey: 'p1'),
      overrides: _clock,
    );

    expect(find.byType(SessionCard), findsOneWidget);
    expect(tester.widget<SessionCard>(find.byType(SessionCard)).age, isNull);
    expect(find.textContaining('active '), findsNothing);
  });

  testWidgets('a pinned row carries the same reading as any other tile', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          title: 'Fix the login flow',
          project: 'popupbits',
          projectId: 'p1',
          status: CompanionSessionStatus.working,
          lastActivityAt: _now.subtract(const Duration(minutes: 12)),
        ),
        summary(
          's2',
          project: 'karmashala',
          projectId: 'p2',
          status: CompanionSessionStatus.idle,
        ),
      ],
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const SessionListScreen(),
      overrides: _clock,
    );

    expect(find.text('active 12m ago'), findsOneWidget);
  });

  group('the reading itself', () {
    test('is the app’s own wording, and null when there is none', () {
      expect(
        companionLastActiveLabel(
          summary('a', lastActivityAt: _now.subtract(const Duration(seconds: 20))),
          _now,
        ),
        'active just now',
      );
      expect(
        companionLastActiveLabel(
          summary('a', lastActivityAt: _now.subtract(const Duration(hours: 2))),
          _now,
        ),
        'active 2h ago',
      );
      expect(companionLastActiveLabel(summary('a'), _now), isNull);
    });

    test('comes off one field, so the host’s new one is a one-line move', () {
      final at = _now.subtract(const Duration(minutes: 5));
      expect(companionLastActiveAt(summary('a', lastActivityAt: at)), at);
      expect(companionLastActiveAt(summary('a')), isNull);
    });
  });
}
