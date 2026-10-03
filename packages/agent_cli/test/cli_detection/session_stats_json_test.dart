import 'package:test/test.dart';
import 'package:agent_cli/src/cli_detection/domain/session_stats.dart';

/// The `sessions.stats` wire form. A server older than a field leaves it out,
/// and the app must read that as "not recorded", never as zero.
void main() {
  group('reasoning per turn', () {
    test('rides beside output per turn, in the same order', () {
      const stats = SessionStats(
        source: SessionStatsSource.localStore,
        outputTokensPerTurn: [120, 4000, 800],
        reasoningTokensPerTurn: [40, 3500, 0],
      );

      final json = stats.toJson();
      expect(json['reasoningTokensPerTurn'], [40, 3500, 0]);

      final back = SessionStats.fromJson(json);
      expect(back.outputTokensPerTurn, [120, 4000, 800]);
      expect(back.reasoningTokensPerTurn, [40, 3500, 0]);
    });

    test('a server that never wrote it reads as not recorded', () {
      final back = SessionStats.fromJson({
        'source': 'localStore',
        'outputTokensPerTurn': [120, 4000],
      });
      expect(back.outputTokensPerTurn, [120, 4000]);
      expect(back.reasoningTokensPerTurn, isNull);
    });

    test('and is left out of the wire form when not recorded', () {
      const stats = SessionStats(
        source: SessionStatsSource.localStore,
        outputTokensPerTurn: [120],
      );
      expect(stats.toJson().containsKey('reasoningTokensPerTurn'), isFalse);
    });
  });

  group('what an agent reports over its protocol', () {
    test('context per turn and the reported cost round-trip', () {
      const stats = SessionStats(
        source: SessionStatsSource.agentReported,
        contextUsedPerTurn: [1800, 2600],
        reportedCost: ReportedCost(amount: 0.02, currency: 'USD'),
      );
      final json = stats.toJson();
      expect(json['source'], 'agentReported');
      expect(json['contextUsedPerTurn'], [1800, 2600]);
      expect(json['reportedCost'], {'amount': 0.02, 'currency': 'USD'});

      final back = SessionStats.fromJson(json);
      expect(back.source, SessionStatsSource.agentReported);
      expect(back.contextUsedPerTurn, [1800, 2600]);
      expect(
        back.reportedCost,
        const ReportedCost(amount: 0.02, currency: 'USD'),
      );
      expect(back.isEmpty, isFalse);
    });

    test('a server that never wrote them reads as not recorded', () {
      final back = SessionStats.fromJson({'source': 'agentReported'});
      expect(back.contextUsedPerTurn, isNull);
      expect(back.reportedCost, isNull);
      expect(back.isEmpty, isTrue);
    });

    test('a malformed cost is not recorded rather than zero', () {
      expect(ReportedCost.fromJson({'amount': 'x', 'currency': 'USD'}), isNull);
      expect(ReportedCost.fromJson({'amount': 1}), isNull);
    });
  });
}
