import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 8, 14, 0);

  group('WriteToken', () {
    test('an unheld token is claimed by the first asker', () {
      final token = WriteToken();
      expect(token.claim('pane-1', t0), isNull);
      expect(token.isHeldBy('pane-1'), isTrue);
      expect(token.holder!.claimedAt, t0);
    });

    test('a second client is refused and told who holds it, with the age', () {
      final token = WriteToken()..claim('pane-1', t0);
      final refusal = token.claim('pane-2', t0.add(const Duration(minutes: 4)));

      expect(refusal, isNotNull);
      expect(refusal!.holder!.clientId, 'pane-1');
      expect(refusal.message, 'write token held by pane-1 (claimed 4m ago)');
    });

    test('re-claiming does not reset how long the holder has been driving', () {
      final token = WriteToken()..claim('pane-1', t0);
      expect(token.claim('pane-1', t0.add(const Duration(minutes: 9))), isNull);
      expect(token.holder!.claimedAt, t0);
    });

    test('only the holder releases', () {
      final token = WriteToken()..claim('pane-1', t0);
      expect(token.release('pane-2'), isFalse);
      expect(token.isHeldBy('pane-1'), isTrue);
      expect(token.release('pane-1'), isTrue);
      expect(token.isHeld, isFalse);
    });

    test('releasing a token never held is not an error', () {
      final token = WriteToken();
      expect(token.release('pane-9'), isFalse);
      token.releaseIfHeldBy('pane-9');
      expect(token.isHeld, isFalse);
    });

    test('a hand-over moves the claim with no gap', () {
      final token = WriteToken()..claim('pane-1', t0);
      final at = t0.add(const Duration(minutes: 2));
      expect(token.handOver('pane-1', 'pane-2', at), isNull);
      expect(token.isHeldBy('pane-2'), isTrue);
      expect(token.holder!.claimedAt, at);
    });

    test('a hand-over from someone who does not hold it is refused', () {
      final token = WriteToken()..claim('pane-1', t0);
      final refusal = token.handOver(
        'pane-3',
        'pane-2',
        t0.add(const Duration(hours: 3)),
      );
      expect(refusal!.message, 'write token held by pane-1 (claimed 3h ago)');
      expect(token.isHeldBy('pane-1'), isTrue);
    });
  });

  group('ClaimRefusal', () {
    test('an unclaimed session says so rather than naming nobody', () {
      expect(
        ClaimRefusal.unclaimed(t0).message,
        'nobody holds the write token for this session; claim it first',
      );
    });
  });

  group('describeAge', () {
    test('reads as an age, never as a bare number', () {
      expect(describeAge(Duration.zero), 'just now');
      expect(describeAge(const Duration(seconds: 12)), '12s ago');
      expect(describeAge(const Duration(minutes: 5)), '5m ago');
      expect(describeAge(const Duration(hours: 5)), '5h ago');
      expect(describeAge(const Duration(days: 9)), '9d ago');
    });
  });
}
