import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/device_keyboard_sink.dart';
import 'package:karmashala_devices/src/domain/device_keyboard.dart';
import 'package:karmashala_devices/src/domain/simulator_backend.dart';
import 'package:karmashala_devices/src/domain/ui_node.dart';

/// Records what the sink asked the backend to do, and can be told to fail.
class _FakeBackend implements SimulatorBackend {
  final List<String> typed = [];
  final List<SimulatorKey> pressed = [];

  /// Thrown by [inputText] and [pressKey] when set, to stand for a
  /// WebDriverAgent that died mid-session.
  Object? failWith;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> attach(String udid) async {}

  @override
  Future<void> detach(String udid) async {}

  @override
  Future<SimulatorScreen?> screen(String udid) async => null;

  @override
  Future<SimulatorVideoFeed> startVideo(
    String udid, {
    int fps = 30,
    double? scale,
  }) async => throw UnimplementedError();

  @override
  Future<void> tap(String udid, int x, int y) async {}

  @override
  Future<void> swipe(
    String udid, {
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    Duration? duration,
  }) async {}

  @override
  Future<void> inputText(String udid, String text) async {
    if (failWith != null) throw failWith!;
    typed.add(text);
  }

  @override
  Future<void> pressKey(String udid, SimulatorKey key) async {
    if (failWith != null) throw failWith!;
    pressed.add(key);
  }

  @override
  Future<void> pressButton(String udid, SimulatorButton button) async {}

  @override
  Future<bool> isLocked(String udid) async => false;

  @override
  Future<void> setLocked(String udid, {required bool locked}) async {}

  @override
  Future<UiHierarchy> describeUi(String udid) async =>
      throw UnimplementedError();
}

DeviceKeycodeIntent _down(
  DesktopKey key, {
  int metaState = AndroidMetaState.none,
}) => DeviceKeycodeIntent(
  action: AndroidKeyAction.down,
  keyCode: androidKeyCodeFor(key) ?? 0,
  logicalKey: key,
  metaState: metaState,
);

void main() {
  late _FakeBackend backend;
  late SimulatorKeyboardSink sink;
  late List<Object> errors;

  setUp(() {
    backend = _FakeBackend();
    errors = [];
    sink = SimulatorKeyboardSink(
      backend: backend,
      udid: 'UDID',
      onError: errors.add,
    );
  });

  test('it announces which transport is carrying the keystrokes', () {
    expect(sink.transport, DeviceKeyboardTransport.webDriverAgent);
    expect(sink.transport.carriesModifiers, isFalse);
  });

  group('characters', () {
    test('are typed as text, not translated into keys', () async {
      // XCUITest's typeText produces whatever the iOS keyboard can, so an
      // accent and an emoji travel as themselves rather than through a map
      // that would have to refuse them.
      expect(sink.send(const DeviceTextIntent('é')), isTrue);
      expect(sink.send(const DeviceTextIntent('🙂')), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(backend.typed, ['é', '🙂']);
      expect(backend.pressed, isEmpty);
      expect(sink.refusal, isNull);
    });
  });

  group('named keys', () {
    test('go out as HID presses, never as typed text', () async {
      // The whole reason `pressKey` exists: posting the XCUIKeyboardKey escape
      // for Left Arrow to /wda/keys inserts U+F702 into the focused field as a
      // character instead of moving the caret.
      expect(sink.send(_down(DesktopKey.arrowLeft)), isTrue);
      expect(sink.send(_down(DesktopKey.backspace)), isTrue);
      expect(sink.send(_down(DesktopKey.enter)), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(backend.pressed, [
        SimulatorKey.arrowLeft,
        SimulatorKey.backspace,
        SimulatorKey.returnKey,
      ]);
      expect(backend.typed, isEmpty);
    });

    test('are pressed once, on the way down only', () async {
      // A press is one whole down-and-up, so acting on the release too would
      // type every key twice.
      sink.send(_down(DesktopKey.backspace));
      sink.send(
        const DeviceKeycodeIntent(
          action: AndroidKeyAction.up,
          keyCode: AndroidKeyCode.del,
          logicalKey: DesktopKey.backspace,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(backend.pressed, [SimulatorKey.backspace]);
    });
  });

  group('degrading honestly', () {
    test('a chord is refused rather than sent stripped of its modifier', () async {
      final sent = sink.send(
        _down(DesktopKey.printable('a'), metaState: AndroidMetaState.ctrlOn),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sent, isFalse);
      // Not "a" typed over the selection the user wanted, and not a bare A.
      expect(backend.typed, isEmpty);
      expect(backend.pressed, isEmpty);
      expect(sink.refusal, DeviceKeyboardTransport.webDriverAgent.limitation);
    });

    test('a key iOS does not have names itself in the refusal', () async {
      final sent = sink.send(_down(DesktopKey.audioVolumeUp));
      await Future<void>.delayed(Duration.zero);

      expect(sent, isFalse);
      expect(backend.pressed, isEmpty);
      expect(sink.refusal, isNotNull);
      expect(sink.refusal, startsWith('iOS has no'));
      // The specific reason, not the transport's blanket line about chords —
      // that would send the user hunting for a modifier problem they do not
      // have.
      expect(
        sink.refusal,
        isNot(DeviceKeyboardTransport.webDriverAgent.limitation),
      );
    });

    test('a refusal is cleared by the next keystroke that goes through', () {
      sink.send(_down(DesktopKey.audioVolumeUp));
      expect(sink.refusal, isNotNull);

      sink.send(const DeviceTextIntent('a'));
      expect(sink.refusal, isNull);
    });

    test('a backend that fails afterwards is reported, not swallowed', () async {
      backend.failWith = StateError('WebDriverAgent went away');

      // `send` cannot know yet — the request has only been posted — so it
      // answers true and the failure arrives on the error channel instead.
      expect(sink.send(const DeviceTextIntent('a')), isTrue);
      expect(sink.send(_down(DesktopKey.arrowUp)), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(2));
      expect(errors.first, isA<StateError>());
    });
  });

  group('the desktop-to-iOS key map', () {
    test('covers the editing and navigation keys', () {
      expect(simulatorKeyFor(DesktopKey.arrowUp), SimulatorKey.arrowUp);
      expect(
        simulatorKeyFor(DesktopKey.arrowDown),
        SimulatorKey.arrowDown,
      );
      expect(
        simulatorKeyFor(DesktopKey.arrowLeft),
        SimulatorKey.arrowLeft,
      );
      expect(
        simulatorKeyFor(DesktopKey.arrowRight),
        SimulatorKey.arrowRight,
      );
      expect(
        simulatorKeyFor(DesktopKey.backspace),
        SimulatorKey.backspace,
      );
      expect(
        simulatorKeyFor(DesktopKey.delete),
        SimulatorKey.forwardDelete,
      );
      expect(simulatorKeyFor(DesktopKey.enter), SimulatorKey.returnKey);
      expect(simulatorKeyFor(DesktopKey.escape), SimulatorKey.escape);
      expect(simulatorKeyFor(DesktopKey.tab), SimulatorKey.tab);
      expect(simulatorKeyFor(DesktopKey.pageUp), SimulatorKey.pageUp);
    });

    test('leaves out the Android hardware keys iOS has no answer for', () {
      // A best-effort substitute here would silently do the wrong thing, which
      // is the same reason `SimulatorButton.forDeviceKey` is partial.
      expect(simulatorKeyFor(DesktopKey.goBack), isNull);
      expect(simulatorKeyFor(DesktopKey.contextMenu), isNull);
      expect(simulatorKeyFor(DesktopKey.audioVolumeUp), isNull);
      expect(simulatorKeyFor(DesktopKey.browserSearch), isNull);
    });

    test('carries the HID keyboard-page usages the simulator was probed with', () {
      // Measured against WebDriverAgent 16.11.4 on an iOS 18.2 simulator:
      // page 0x07 with these usages moved the caret, deleted, dismissed the
      // field's edit and submitted it respectively.
      expect(SimulatorKey.arrowLeft.hidUsage, 0x50);
      expect(SimulatorKey.backspace.hidUsage, 0x2A);
      expect(SimulatorKey.escape.hidUsage, 0x29);
      expect(SimulatorKey.returnKey.hidUsage, 0x28);
    });
  });
}
