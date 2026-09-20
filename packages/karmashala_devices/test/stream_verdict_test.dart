// The whole rule for condemning a live view, in one table. Keying it on the
// plumbing — socket open, server alive, bytes and frames arriving — traded a
// restart loop for the opposite failure, because every one of those signals
// stops at the socket. So the rule reads a third clock, when a frame was last
// *delivered to the player*, and whether the user is asking for anything.
import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/device_stream.dart';

const _stall = Duration(seconds: 6);

StreamVerdict? _judge({
  Duration sinceFrame = Duration.zero,
  Duration sinceByte = Duration.zero,
  Duration? sinceDelivery = Duration.zero,
  Duration? sinceInput,
  int unansweredInputs = 0,
  bool framesSeen = true,
  bool watching = true,
}) => judgeStream(
  StreamClocks(
    sinceFrame: sinceFrame,
    sinceByte: sinceByte,
    sinceDelivery: sinceDelivery,
    sinceInput: sinceInput,
    unansweredInputs: unansweredInputs,
    framesSeen: framesSeen,
    watching: watching,
  ),
  stallTimeout: _stall,
);

void main() {
  group('judgeStream', () {
    test('says nothing before the first frame', () {
      // Nothing has proven itself yet; the start path is still reporting.
      expect(_judge(framesSeen: false), isNull);
    });

    test('frames arriving and reaching the player is live', () {
      expect(_judge()?.state, DeviceStreamState.live);
    });

    test('a device with nothing to draw is idle, not a fault', () {
      // The 1.6.0 fix, which must survive this one: an untouched phone sends
      // nothing at all, and that is not a reason to tear a stream down.
      final verdict = _judge(
        sinceFrame: const Duration(minutes: 5),
        sinceByte: const Duration(minutes: 5),
        sinceDelivery: const Duration(minutes: 5),
      );
      expect(verdict?.state, DeviceStreamState.idle);
      expect(verdict?.detail, 'No screen changes for 300s.');
    });

    test('bytes that decode into nothing are still a fault', () {
      final verdict = _judge(
        sinceFrame: const Duration(seconds: 9),
        sinceByte: const Duration(seconds: 1),
        sinceDelivery: const Duration(seconds: 9),
      );
      expect(verdict?.state, DeviceStreamState.stalled);
      expect(verdict?.detail, contains('no frame has decoded'));
    });

    test('frames the player never shows are a fault, though everything is '
        'connected', () {
      // The failure with no signal at all in 1.6.0: the socket delivers, `live`
      // is reported, and the picture has not moved since the player stopped.
      final verdict = _judge(
        sinceFrame: const Duration(milliseconds: 100),
        sinceByte: const Duration(milliseconds: 100),
        sinceDelivery: const Duration(seconds: 8),
      );
      expect(verdict?.state, DeviceStreamState.stalled);
      expect(verdict?.detail, contains('picture has not updated'));
      expect(verdict?.detail, contains('8s'));
    });

    test('a player that has never been handed a frame is not accused', () {
      // No viewer has connected yet — the delivery clock has never started, so
      // it is not evidence of anything.
      expect(
        _judge(
          sinceFrame: const Duration(milliseconds: 100),
          sinceDelivery: null,
        )?.state,
        DeviceStreamState.live,
      );
    });

    test('a window nobody can see is not accused of being behind', () {
      // A minimised window may stop taking frames, which looks exactly like a
      // player that has seized up.
      expect(
        _judge(
          sinceFrame: const Duration(milliseconds: 100),
          sinceDelivery: const Duration(minutes: 4),
          watching: false,
        )?.state,
        DeviceStreamState.live,
      );
    });

    test('input that the picture never answers is a fault', () {
      // The owner's report, exactly: stale, and interacting changes nothing.
      final verdict = _judge(
        sinceFrame: const Duration(seconds: 30),
        sinceByte: const Duration(seconds: 30),
        sinceDelivery: const Duration(seconds: 30),
        sinceInput: const Duration(seconds: 5),
        unansweredInputs: 3,
      );
      expect(verdict?.state, DeviceStreamState.stalled);
      expect(verdict?.detail, contains('has not answered'));
    });

    test('one unanswered touch is not evidence', () {
      // Tapping somewhere that does nothing is an ordinary thing to do, and a
      // rule that restarts on it is the eleven-second loop with extra steps.
      expect(
        _judge(
          sinceFrame: const Duration(seconds: 30),
          sinceByte: const Duration(seconds: 30),
          sinceDelivery: const Duration(seconds: 30),
          sinceInput: const Duration(seconds: 5),
          unansweredInputs: 1,
        )?.state,
        DeviceStreamState.idle,
      );
    });

    test('input still in flight is given time to be answered', () {
      // Mid-drag, and `adb shell input` takes a couple of hundred milliseconds
      // to reach the device at all.
      expect(
        _judge(
          sinceFrame: const Duration(seconds: 30),
          sinceByte: const Duration(seconds: 30),
          sinceDelivery: const Duration(seconds: 30),
          sinceInput: const Duration(milliseconds: 400),
          unansweredInputs: 5,
        )?.state,
        DeviceStreamState.idle,
      );
    });

    test('an unanswered interaction stays a fault until the picture answers', () {
      // Deliberately not aged out: once reconnection has given up, this verdict
      // is the only thing holding the restart button on screen.
      final verdict = _judge(
        sinceFrame: const Duration(hours: 1),
        sinceByte: const Duration(hours: 1),
        sinceDelivery: const Duration(hours: 1),
        sinceInput: const Duration(hours: 1),
        unansweredInputs: 4,
      );
      expect(verdict?.state, DeviceStreamState.stalled);
      expect(verdict?.detail, contains('has not answered'));
    });

    test('an answered touch never reaches the rule', () {
      // Frames arriving is what "answered" means, and it is checked first.
      expect(
        _judge(
          sinceInput: const Duration(seconds: 5),
          unansweredInputs: 9,
        )?.state,
        DeviceStreamState.live,
      );
    });
  });
}
