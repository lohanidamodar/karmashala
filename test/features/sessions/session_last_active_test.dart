/// **One definition of "last active", and the order it produces.**
///
/// The owner's report: "the sessions were supposed to be ordered by last active
/// time". Three lists order sessions — the Explorer's forest, Quick Open and the
/// host snapshot walk the phone's list comes from — and each used to pick its
/// own key, so the desktop and the phone could disagree about which session was
/// freshest. These are the rules all three now share.
library;

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_session/resume.dart';

void main() {
  final t9 = DateTime.utc(2026, 8, 31, 9);
  final t10 = DateTime.utc(2026, 8, 31, 10);
  final t11 = DateTime.utc(2026, 8, 31, 11);

  SessionActivityOrder order(SessionLastActive lastActive, DateTime createdAt) =>
      (lastActive: lastActive, createdAt: createdAt);

  group('the reading', () {
    test('no reading is unknown, never a zero', () {
      expect(newestLastActive(), SessionLastActive.unknown);
      expect(newestLastActive().at, isNull);
      expect(newestLastActive().isKnown, isFalse);
      expect(newestLastActive().label(t11), isNull);
    });

    test('the newest of the readings wins, and names its source', () {
      expect(
        newestLastActive(agentEvidenceAt: t11, storeModifiedAt: t9),
        SessionLastActive(at: t11, source: LastActiveSource.agent),
      );
      expect(
        newestLastActive(agentEvidenceAt: t9, storeModifiedAt: t11),
        SessionLastActive(at: t11, source: LastActiveSource.store),
      );
    });

    test('a tie goes to the finer source', () {
      expect(
        newestLastActive(agentEvidenceAt: t10, storeModifiedAt: t10).source,
        LastActiveSource.agent,
      );
    });

    test('one reading on its own is that reading', () {
      expect(newestLastActive(agentEvidenceAt: t10).at, t10);
      expect(newestLastActive(storeModifiedAt: t10).source,
          LastActiveSource.store);
    });

    test('it never asks a clock', () {
      // The whole function is a pure choice between the values handed to it:
      // the same inputs answer the same thing an hour later, which is what lets
      // the desktop, the phone and this test agree.
      final before = newestLastActive(agentEvidenceAt: t10);
      final after = newestLastActive(agentEvidenceAt: t10);
      expect(before, after);
      expect(before.at, t10, reason: 'not "now", and not the moment we asked');
    });

    test('"active 3m ago", in the app\'s own wording', () {
      expect(
        newestLastActive(agentEvidenceAt: t11).label(
          t11.add(const Duration(minutes: 3)),
        ),
        'active 3m ago',
      );
      expect(
        newestLastActive(agentEvidenceAt: t11).label(
          t11.add(const Duration(days: 2)),
        ),
        'active 2d ago',
      );
      expect(
        newestLastActive(agentEvidenceAt: t11).label(t11),
        'active just now',
      );
    });
  });

  group('a status report', () {
    AgentStatusReport report(AgentStatusSource source, {DateTime? modified}) =>
        AgentStatusReport(
          agentId: 'claudeCode',
          sessionId: 'x',
          status: AgentActivityStatus.working,
          source: source,
          observedAt: t10,
          sourceModifiedAt: modified,
        );

    test('a source that could tell us nothing contributes no timestamp', () {
      expect(agentEvidenceAt(null), isNull);
      expect(agentEvidenceAt(report(AgentStatusSource.none)), isNull);
    });

    test('a transcript is dated by the file, a hook by the callback', () {
      // The distinction §19 exists for: ageing the poll would make a week-old
      // transcript look live.
      expect(
        agentEvidenceAt(report(AgentStatusSource.stateFile, modified: t9)),
        t9,
      );
      expect(agentEvidenceAt(report(AgentStatusSource.hook)), t10);
      expect(agentEvidenceAt(report(AgentStatusSource.terminalGrid)), t10);
    });
  });

  group('the order', () {
    test('most recently active first', () {
      final rows = [
        order(newestLastActive(agentEvidenceAt: t9), t9),
        order(newestLastActive(agentEvidenceAt: t11), t9),
        order(newestLastActive(agentEvidenceAt: t10), t9),
      ]..sort(compareByLastActive);
      expect([for (final row in rows) row.lastActive.at], [t11, t10, t9]);
    });

    test('a tie is broken by createdAt, newest first', () {
      final rows = [
        order(newestLastActive(agentEvidenceAt: t10), t9),
        order(newestLastActive(agentEvidenceAt: t10), t11),
      ]..sort(compareByLastActive);
      expect([for (final row in rows) row.createdAt], [t11, t9]);
    });

    test('a session we hold no reading for sorts last', () {
      // Not oldest: an unknown reading is not an idle-since-the-epoch one, and
      // placing it among the stale rows would be a claim we cannot make. It
      // goes after everything we can speak for — even a session created after
      // it, and even one last active years ago.
      final ancient = DateTime.utc(2020);
      final rows = [
        order(SessionLastActive.unknown, t11),
        order(newestLastActive(agentEvidenceAt: ancient), t9),
      ]..sort(compareByLastActive);
      expect([for (final row in rows) row.createdAt], [t9, t11]);
    });

    test('two sessions we know nothing about fall back to createdAt', () {
      final rows = [
        order(SessionLastActive.unknown, t9),
        order(SessionLastActive.unknown, t11),
        order(SessionLastActive.unknown, t10),
      ]..sort(compareByLastActive);
      expect([for (final row in rows) row.createdAt], [t11, t10, t9]);
    });

    test('the comparator is a total order — no clock, so no drift', () {
      final a = order(newestLastActive(agentEvidenceAt: t10), t9);
      final b = order(newestLastActive(agentEvidenceAt: t11), t9);
      expect(compareByLastActive(a, b), greaterThan(0));
      expect(compareByLastActive(b, a), lessThan(0));
      expect(compareByLastActive(a, a), 0);
    });
  });
}
