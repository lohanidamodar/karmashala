import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

void main() {
  late Duration now;
  StreamFlow flow() => StreamFlow(
    clock: () => now,
    highWatermark: 300,
    lowWatermark: 100,
    hardLimit: 1000,
    stallTimeout: const Duration(seconds: 10),
  );

  setUp(() => now = Duration.zero);

  test('a phone that never acks is served as before', () {
    final f = flow();
    for (var seq = 0; seq < 100; seq++) {
      expect(f.admit(), StreamAdmission.send);
      f.sent(seq, 100);
    }
    expect(f.unackedBytes, 0, reason: 'nothing is counted before an ack');
  });

  test('pauses at the high watermark and resumes below the low one', () {
    final f = flow()..ack(-1);
    for (var seq = 0; seq < 3; seq++) {
      expect(f.admit(), StreamAdmission.send);
      f.sent(seq, 100);
    }
    expect(f.admit(), StreamAdmission.paused);
    expect(f.ack(0), isFalse, reason: '200 unacked is still above 100');
    expect(f.admit(), StreamAdmission.paused);
    expect(f.ack(1), isTrue, reason: 'this ack reopened the stream');
    expect(f.admit(), StreamAdmission.send);
  });

  test('answers count against the window even though they are never held', () {
    final f = flow()..ack(-1);
    f.sent(0, 350);
    expect(f.admit(), StreamAdmission.paused);
  });

  test('fails closed once, after a stall with no ack progress', () {
    final f = flow()..ack(-1);
    for (var seq = 0; seq < 3; seq++) {
      f.sent(seq, 100);
    }
    expect(f.admit(), StreamAdmission.paused);
    now = const Duration(seconds: 11);
    expect(f.admit(), StreamAdmission.failed);
    expect(f.admit(), StreamAdmission.paused, reason: 'named once, not per frame');
    expect(f.unackedBytes, 0);
    expect(f.ack(1), isTrue, reason: 'any ack proves a reader again');
    expect(f.admit(), StreamAdmission.send);
  });

  test('progress resets the stall clock', () {
    final f = flow()..ack(-1);
    for (var seq = 0; seq < 5; seq++) {
      f.sent(seq, 100);
    }
    expect(f.admit(), StreamAdmission.paused);
    now = const Duration(seconds: 8);
    f.ack(0);
    now = const Duration(seconds: 16);
    expect(f.admit(), StreamAdmission.paused);
  });

  test('fails closed past the hard limit whatever else is true', () {
    final f = flow()..ack(-1);
    f.sent(0, 1001);
    expect(f.admit(), StreamAdmission.failed);
  });

  test('an old or repeated ack retires nothing', () {
    final f = flow()..ack(-1);
    f.sent(0, 100);
    f.sent(1, 100);
    f.ack(1);
    f.sent(2, 100);
    expect(f.ack(1), isFalse);
    expect(f.unackedBytes, 100);
  });
}
