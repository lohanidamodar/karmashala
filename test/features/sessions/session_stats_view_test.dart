import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/cli_detection/domain/session_stats.dart';
import 'package:karmashala/src/features/sessions/application/session_stats_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_stats_dialog.dart';

/// The stats dialog's wording and its number formatting, asserted without
/// pumping a frame — the same bargain `UsageChipView` makes.
void main() {
  AgentDescriptor descriptor(AgentStoreFormat? format) => AgentDescriptor(
    id: 'x',
    displayName: 'X',
    binaries: const AgentBinaries(windows: ['x'], posix: ['x']),
    store: format == null
        ? null
        : AgentStoreSpec(homeDirectoryName: '.x', format: format),
  );

  group('which agents have anything to count', () {
    test('the two that write a readable transcript do', () {
      expect(
        agentStoreRecordsStats(descriptor(AgentStoreFormat.claudeJsonl)),
        isTrue,
      );
      expect(
        agentStoreRecordsStats(descriptor(AgentStoreFormat.codexRollout)),
        isTrue,
      );
    });

    test('a store that yields identity without content does not', () {
      // Antigravity: the directory is readable, the messages inside it are
      // protobuf in an unpublished schema. Identity is not a count.
      expect(
        agentStoreRecordsStats(descriptor(AgentStoreFormat.antigravityStore)),
        isFalse,
      );
    });

    test('an agent with no declared store does not', () {
      expect(agentStoreRecordsStats(descriptor(null)), isFalse);
      expect(agentStoreRecordsStats(descriptor(AgentStoreFormat.none)), isFalse);
      expect(agentStoreRecordsStats(null), isFalse);
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
