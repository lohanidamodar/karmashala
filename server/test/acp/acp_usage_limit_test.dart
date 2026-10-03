import 'package:karmashala_acp/karmashala_acp.dart' show AcpRpcError;
import 'package:karmashala_host/src/acp/acp_usage_limit.dart';
import 'package:test/test.dart';

/// A turn an ACP agent refused on a limit, read from the error's own words:
/// the protocol has no code for it.
void main() {
  final now = DateTime.utc(2026, 10, 3, 12);

  group('isUsageLimitError', () {
    for (final words in [
      'Usage limit reached|1759500000',
      "You've hit your usage limit. Try again in 2h 5m.",
      "You've hit your limit",
      '429 Too Many Requests',
      'RESOURCE_EXHAUSTED: Quota exceeded for this model',
      'rate_limit_error: slow down',
    ]) {
      test('"$words" is a limit', () {
        expect(isUsageLimitError(AcpRpcError(-32603, words)), isTrue);
      });
    }

    test('the data counts as much as the message', () {
      expect(
        isUsageLimitError(
          const AcpRpcError(-32603, 'Internal error', data: {
            'type': 'usage_limit',
          }),
        ),
        isTrue,
      );
    });

    test('any other failure is not', () {
      expect(
        isUsageLimitError(const AcpRpcError(-32603, 'tool crashed: ENOENT')),
        isFalse,
      );
      expect(
        isUsageLimitError(const AcpRpcError(-32602, 'Invalid params')),
        isFalse,
      );
    });
  });

  group('usageLimitResetIn', () {
    test('epoch seconds', () {
      final at = now.add(const Duration(hours: 3));
      expect(
        usageLimitResetIn([
          'Usage limit reached|${at.millisecondsSinceEpoch ~/ 1000}',
        ], now),
        at,
      );
    });

    test('an ISO time with its offset', () {
      expect(
        usageLimitResetIn([
          '{"resetsAt":"2026-10-03T15:30:00+02:00"}',
        ], now),
        DateTime.utc(2026, 10, 3, 13, 30),
      );
    });

    test('a span from now, in any spelling', () {
      expect(
        usageLimitResetIn(['Try again in 2h 5m.'], now),
        now.add(const Duration(hours: 2, minutes: 5)),
      );
      expect(
        usageLimitResetIn(['retry after 2 hours and 30 minutes'], now),
        now.add(const Duration(hours: 2, minutes: 30)),
      );
      expect(
        usageLimitResetIn(['Please retry in 45.5s'], now),
        now.add(const Duration(seconds: 45, milliseconds: 500)),
      );
    });

    test('a wall-clock time, a past one, or one too far off is not read', () {
      expect(usageLimitResetIn(['resets 3pm'], now), isNull);
      expect(
        usageLimitResetIn(['limit|${now.millisecondsSinceEpoch ~/ 1000 - 60}'], now),
        isNull,
      );
      expect(usageLimitResetIn(['try again in 30 days'], now), isNull);
      expect(usageLimitResetIn(['Usage limit reached'], now), isNull);
    });
  });
}
