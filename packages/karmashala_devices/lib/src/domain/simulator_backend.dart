import 'dart:async';
import 'dart:typed_data';

import 'device_input.dart';
import 'ui_node.dart';

/// One encoded video frame, in the shape the live-view pipeline already eats —
/// the same three facts `ScrcpyFrame` carries, so `TsMuxer` needs no second path.
class VideoAccessUnit {
  const VideoAccessUnit({
    required this.bytes,
    required this.ptsUs,
    required this.isKeyFrame,
    this.isCodecConfig = false,
  });

  /// H.264 Annex-B: 4-byte start codes, not AVCC length prefixes. A backend
  /// that speaks AVCC converts before it gets here — one place, not two.
  final Uint8List bytes;

  final int ptsUs;
  final bool isKeyFrame;

  /// SPS/PPS rather than a picture. Cached and republished ahead of every
  /// keyframe so a viewer joining late can decode from it.
  final bool isCodecConfig;
}

/// A running video feed from one simulator. A **URL**, not a frame stream:
/// muxing is the backend's business, and frames here would push it into the pane.
class SimulatorVideoFeed {
  const SimulatorVideoFeed({required this.url, required this.stop, this.size});

  /// What the video player opens. Loopback, always.
  final Uri url;

  /// The encoded picture's size, when the backend knows it up front. Neither the
  /// device's screen size nor the space taps are in — see [SimulatorScreen].
  final DeviceScreenSize? size;

  final Future<void> Function() stop;
}

/// The two sizes a simulator has, and which is which. Taps and element frames
/// are in **points**; the backing store is pixels, 3x apart on a 3x device.
class SimulatorScreen {
  const SimulatorScreen({required this.points, this.pixels});

  /// The space taps and element frames live in.
  final DeviceScreenSize points;

  /// The backing store, when known. For display and aspect ratio only.
  final DeviceScreenSize? pixels;

  /// How many pixels to a point, or null when the pixel size is unknown.
  double? get scale => pixels == null ? null : pixels!.width / points.width;
}

/// A hardware button, in the vocabulary iOS actually has. [forDeviceKey] is
/// deliberately partial: iOS has no system back or recents key to substitute.
enum SimulatorButton {
  home,
  lock,
  sideButton,
  siri,
  applePay;

  static SimulatorButton? forDeviceKey(DeviceKey key) => switch (key) {
    DeviceKey.home => SimulatorButton.home,
    DeviceKey.power => SimulatorButton.lock,
    _ => null,
  };
}

/// A key on the keyboard iOS believes is plugged into the device. Not
/// [inputText]: measured, posting an XCUIKeyboardKey escape to `/wda/keys` types
/// the private-use code point as an invisible character instead of pressing the
/// key. [hidUsage] is the USB HID keyboard page (`0x07`) usage, which does not.
enum SimulatorKey {
  returnKey(0x28),
  escape(0x29),
  backspace(0x2A),
  tab(0x2B),
  capsLock(0x39),
  f1(0x3A),
  f2(0x3B),
  f3(0x3C),
  f4(0x3D),
  f5(0x3E),
  f6(0x3F),
  f7(0x40),
  f8(0x41),
  f9(0x42),
  f10(0x43),
  f11(0x44),
  f12(0x45),
  insert(0x49),
  home(0x4A),
  pageUp(0x4B),
  forwardDelete(0x4C),
  end(0x4D),
  pageDown(0x4E),
  arrowRight(0x4F),
  arrowLeft(0x50),
  arrowDown(0x51),
  arrowUp(0x52);

  const SimulatorKey(this.hidUsage);

  /// The usage on HID keyboard page `0x07`.
  final int hidUsage;
}

/// Everything a live, interactive simulator view needs that `simctl` cannot do.
/// The interface exists so the thing behind it can be replaced, which is why
/// nothing here names idb. Listing, booting, screenshots and logs stay on
/// `simctl`, so the pane survives the backend being unavailable.
abstract interface class SimulatorBackend {
  /// Stable identifier, for logs and for remembering a user's choice.
  String get id;

  /// What to call it in the UI when there is a choice to explain.
  String get displayName;

  /// Whether this backend can run here, right now. Cheap and side-effect free:
  /// it is called to decide what to offer, so it must not start anything.
  Future<bool> isAvailable();

  /// Prepares the backend for [udid], if it needs preparing. Idempotent, and up
  /// front so a failure surfaces attached to what the user just asked for.
  Future<void> attach(String udid);

  /// The screen's two sizes, or null when this backend cannot say.
  Future<SimulatorScreen?> screen(String udid);

  Future<SimulatorVideoFeed> startVideo(String udid, {int fps, double? scale});

  /// Taps a point **in points**, not pixels. See [SimulatorScreen].
  Future<void> tap(String udid, int x, int y);

  Future<void> swipe(
    String udid, {
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    Duration? duration,
  });

  Future<void> inputText(String udid, String text);

  Future<void> pressButton(String udid, SimulatorButton button);

  /// Presses one key on the device's keyboard, down and up. Whole presses only,
  /// so nothing is left held — and a **modifier cannot span another key**.
  Future<void> pressKey(String udid, SimulatorKey key);

  /// Whether the device is showing its lock screen.
  Future<bool> isLocked(String udid);

  /// Locks or unlocks the device. Both directions, because locking is a state:
  /// a button that could only lock leaves nothing on the toolbar to undo it.
  Future<void> setLocked(String udid, {required bool locked});

  // There is deliberately no app switcher. WebDriverAgent's synthesized touches
  // are delivered into the foreground application, so they never reach the
  // system gesture SpringBoard handles — confirmed against a real device.

  /// The accessibility tree of whatever is on screen, mapped onto the same
  /// [UiHierarchy] the Android side produces so queries and taps-by-label are
  /// written once.
  Future<UiHierarchy> describeUi(String udid);

  /// Releases whatever [attach] took. Safe to call when nothing was attached.
  Future<void> detach(String udid);
}
