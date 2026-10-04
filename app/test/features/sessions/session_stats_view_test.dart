import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala/src/features/sessions/application/session_stats_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_stats_dialog.dart';
import 'package:karmashala/src/features/sessions/presentation/session_stats_sections.dart';

/// The stats dialog's wording and its number formatting, asserted without
/// pumping a frame — the same bargain `UsageChipView` makes.
void main() {
  const x = AgentDescriptor(
    id: 'x',
    displayName: 'X',
    binaries: AgentBinaries(windows: ['x'], posix: ['x']),
    store: AgentStoreSpec(homeDirectoryName: '.x'),
  );

  group('which agents have anything to count', () {
    test('the two that write a readable transcript do', () {
      expect(
        agentStoreRecordsStats(const ClaudeCodeAdapter(descriptor: x)),
        isTrue,
      );
      expect(agentStoreRecordsStats(const CodexAdapter(descriptor: x)), isTrue);
    });

    test('a store that yields identity without content does not', () {
      // Antigravity: the directory is readable, the messages inside it are
      // protobuf in an unpublished schema. Identity is not a count.
      expect(
        agentStoreRecordsStats(const AntigravityAdapter(descriptor: x)),
        isFalse,
      );
    });

    test('an agent with no declared store does not', () {
      expect(agentStoreRecordsStats(const DataOnlyAgentAdapter(x)), isFalse);
      expect(agentStoreRecordsStats(null), isFalse);
    });

    test('an agent spoken to over ACP does: the server keeps its rows', () {
      // Decided by the adapter declaring `acp`, never by its id.
      for (final adapter in AgentRegistry.builtIn.adapters) {
        if (adapter.acp != null) {
          expect(agentStoreRecordsStats(adapter), isTrue, reason: adapter.id);
        }
      }
    });
  });

  group('provenance', () {
    test('a computed answer names the store it came from', () {
      final view = SessionStatsView.computed(
        const SessionStats(source: SessionStatsSource.localStore),
        'Claude Code',
      );
      expect(sessionStatsProvenance(view), contains('Claude Code'));
      expect(sessionStatsProvenance(view), contains('own record'));
    });

    test('an asked answer says it was asked', () {
      final view = SessionStatsView.computed(
        const SessionStats(source: SessionStatsSource.agentOutput),
        'Codex',
      );
      expect(sessionStatsProvenance(view), 'Asked Codex directly');
    });

    test('an unavailable answer claims no origin at all', () {
      const view = SessionStatsView.unavailable(
        SessionStatsUnavailable.agentRecordsNoCounts,
        'Antigravity',
      );
      expect(sessionStatsProvenance(view), 'Nothing to count');
    });

    test('an answer the agent reported says so', () {
      final view = SessionStatsView.computed(
        const SessionStats(source: SessionStatsSource.agentReported),
        'Claude Code · Chat',
      );
      expect(
        sessionStatsProvenance(view),
        startsWith('Reported by Claude Code · Chat'),
      );
      expect(sessionStatsProvenance(view), contains('the server kept'));
    });
  });

  group('what the agent reported', () {
    test('a cost is written as the agent gave it', () {
      expect(
        formatReportedCost(const ReportedCost(amount: 1.5, currency: 'USD')),
        '1.50 USD',
      );
      expect(
        formatReportedCost(const ReportedCost(amount: 0.0042, currency: 'EUR')),
        '0.0042 EUR',
      );
      expect(
        formatReportedCost(const ReportedCost(amount: 0, currency: '')),
        '0.00',
      );
    });

    test('context per turn names the latest and the peak', () {
      expect(
        contextPerTurnSummary([1000, 4000, 2500]),
        'Latest 2.5k at turn 3 · peak 4k at turn 2',
      );
    });
  });

  group('why there is nothing to show', () {
    test('a store with no counts says so, and says nothing is hidden', () {
      final text = sessionStatsExplanation(
        SessionStatsUnavailable.agentRecordsNoCounts,
        'Antigravity',
      );
      expect(text, startsWith('Antigravity records no counts'));
      expect(text, contains('nothing on disk'));
    });

    test('a session that has not spoken yet says that instead', () {
      final text = sessionStatsExplanation(
        SessionStatsUnavailable.transcriptNotFound,
        'Codex',
      );
      expect(text, contains('has not written a file'));
      expect(text, contains('first turn'));
    });

    test('an agent we cannot name still reads as a sentence', () {
      final text = sessionStatsExplanation(
        SessionStatsUnavailable.transcriptNotFound,
        '',
      );
      expect(text, startsWith('This agent has not written'));
    });
  });

  group('formatting', () {
    test('a count is grouped', () {
      expect(formatStatCount(0), '0');
      expect(formatStatCount(999), '999');
      expect(formatStatCount(1000), '1,000');
      expect(formatStatCount(41611532), '41,611,532');
    });

    test('a count nobody recorded is a word, never a zero', () {
      expect(formatStatCount(null), kStatNotRecorded);
      expect(formatStatCount(null), isNot('0'));
    });

    test('a span reads at two units', () {
      expect(formatStatSpan(const Duration(seconds: 12)), '12s');
      expect(formatStatSpan(const Duration(minutes: 45)), '45m');
      expect(formatStatSpan(const Duration(hours: 2, minutes: 11)), '2h 11m');
      expect(formatStatSpan(const Duration(days: 3, hours: 4)), '3d 4h');
      expect(formatStatSpan(null), kStatNotRecorded);
    });

    test('a moment reads to the minute', () {
      final at = DateTime(2026, 3, 7, 9, 5);
      expect(formatStatMoment(at), '2026-03-07 09:05');
      expect(formatStatMoment(null), kStatNotRecorded);
    });
  });

  group('where the lifetime numbers came from', () {
    test('a cache dates itself and warns that it lags', () {
      final line = lifetimeStatsProvenance(
        LifetimeStats(
          source: LifetimeStatsSource.agentCache,
          computedAt: DateTime.utc(2026, 2, 24),
        ),
        'Claude Code',
      );
      expect(line, contains('Claude Code\u2019s own /stats cache'));
      expect(line, contains('2026-02-24'));
      expect(line, contains('rewritten only when that screen is run'));
      expect(line, contains('smaller'));
    });

    test('an undated cache still warns, without inventing a date', () {
      final line = lifetimeStatsProvenance(
        const LifetimeStats(source: LifetimeStatsSource.agentCache),
        'Claude Code',
      );
      expect(line, isNot(contains('last written')));
      expect(line, contains('rewritten only when that screen is run'));
    });

    test('an index says it is current instead', () {
      final line = lifetimeStatsProvenance(
        const LifetimeStats(source: LifetimeStatsSource.agentIndex),
        'Codex',
      );
      expect(line, 'Codex\u2019s own thread index, kept current as it runs.');
      expect(line, isNot(contains('older')));
    });
  });

  group('why there are no lifetime numbers', () {
    test('an agent with no books says nothing was added up for it', () {
      final text = lifetimeStatsExplanation(
        LifetimeStatsUnavailable.agentKeepsNoAggregate,
        'Antigravity',
      );
      expect(text, startsWith('Antigravity keeps no lifetime totals'));
      expect(text, contains('does not add sessions together'));
      // The reason we refuse to synthesise one is on screen, not just in a
      // commit message.
      expect(text, contains('replay'));
    });

    test('books that exist but were never written here say that', () {
      final text = lifetimeStatsExplanation(
        LifetimeStatsUnavailable.sourceNotFound,
        'Claude Code',
      );
      expect(text, contains('none could be read on this machine'));
    });
  });

  group('how old a cache is', () {
    final now = DateTime.utc(2026, 9, 2, 12);

    test('it reads at one unit', () {
      expect(formatStatAge(now, now: now), 'just now');
      expect(
        formatStatAge(now.subtract(const Duration(minutes: 1)), now: now),
        '1 minute ago',
      );
      expect(
        formatStatAge(now.subtract(const Duration(minutes: 40)), now: now),
        '40 minutes ago',
      );
      expect(
        formatStatAge(now.subtract(const Duration(hours: 5)), now: now),
        '5 hours ago',
      );
      expect(
        formatStatAge(DateTime.utc(2026, 2, 24), now: now),
        '190 days ago',
      );
    });

    test('a clock that ran backwards is not negative days ago', () {
      expect(
        formatStatAge(now.add(const Duration(hours: 3)), now: now),
        'just now',
      );
    });

    test('a day prints as a day, with no invented midnight', () {
      expect(formatStatDay(DateTime(2026, 2, 24)), '2026-02-24');
    });
  });

  group('the totals a tally will and will not claim', () {
    test('reasoning is inside output, so it is not added again', () {
      const tokens = TokenTally(
        input: 500,
        output: 90,
        cacheCreated: 0,
        cacheRead: 400,
        reasoning: 30,
      );
      expect(tokens.total, 990);
    });

    test('a tally nobody filled in has no total', () {
      expect(TokenTally.unknown.total, isNull);
      expect(TokenTally.unknown.isUnknown, isTrue);
    });

    test('a span that runs backwards is refused rather than negated', () {
      final stats = SessionStats(
        source: SessionStatsSource.localStore,
        firstActivityAt: DateTime.utc(2026, 5, 2),
        lastActivityAt: DateTime.utc(2026, 5, 1),
      );
      expect(stats.span, isNull);
    });
  });
}
