import 'dart:async';
import 'dart:typed_data';

import 'device_input.dart';
import 'ui_node.dart';

/// One encoded video frame, in the shape the live-view pipeline already eats.
///
/// Deliberately the same three facts `ScrcpyFrame` carries — Annex-B bytes, a
/// microsecond presentation timestamp, and whether this is a keyframe —
/// because that is exactly what `TsMuxer` needs and what the Android path has
/// been feeding it since it was written. A backend that can produce this
/// reuses the whole of the pipeline downstream of here: muxing, the loopback
/// server, and the player.
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

/// A running video feed from one simulator.
///
/// A **URL**, not a frame stream, because that is what the player needs and
/// because the two backends reach it by different routes: one produces H.264
/// access units that have to be muxed into a container first, the other already
/// serves multipart JPEG over HTTP. Muxing is the backend's business, and
/// exposing frames here would push it into the pane.
class SimulatorVideoFeed {
  const SimulatorVideoFeed({
    required this.url,
    required this.stop,
    this.size,
  });

  /// What the video player opens. Loopback, always.
  final Uri url;

  /// The encoded picture's size, when the backend knows it up front. It is not
  /// necessarily the device's screen size — a backend may scale — and it is
  /// not the space taps are in either. See [SimulatorScreen].
  final DeviceScreenSize? size;

  final Future<void> Function() stop;
}

/// The two sizes a simulator has, and which is which.
///
/// Keeping them apart is not pedantry. idb reports element frames — and takes
/// taps — in **points** (an iPhone 17 Pro reads 402x874), while `simctl io
/// enumerate` reports the backing store in **pixels** (1206x2622). Using the
/// pixel size to place a tap on a 3x device lands it three times too far down
/// and to the right, off the screen entirely.
class SimulatorScreen {
  const SimulatorScreen({required this.points, this.pixels});

  /// The space taps and element frames live in.
  final DeviceScreenSize points;

  /// The backing store, when known. For display and aspect ratio only.
  final DeviceScreenSize? pixels;

  /// How many pixels to a point, or null when the pixel size is unknown.
  double? get scale =>
      pixels == null ? null : pixels!.width / points.width;
}

/// A hardware button, in the vocabulary iOS actually has.
///
/// Not [DeviceKey]: that enum carries an Android `KEYCODE_*` per member, and
/// iOS has neither those codes nor most of those buttons. The mapping between
/// them is [forDeviceKey], and it is deliberately partial — iOS has no system
/// back button (an app draws its own) and no recents key, so pressing a
/// best-effort substitute would silently do the wrong thing.
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

/// Everything a live, interactive simulator view needs that `simctl` cannot do.
///
/// **This interface exists so the thing behind it can be replaced.** Today it
/// is `idb_companion`, vendored and driven over its own protocol. It could
/// equally be a Swift plugin of ours talking to CoreSimulator directly, or a
/// WebDriverAgent bundle, and none of the pane, the providers or the MCP tools
/// should have to know. So nothing in this file names idb, and nothing above it
/// imports an idb type.
///
/// What is deliberately **not** here: listing, booting, screenshots, app
/// lifecycle and logs. `simctl` does all of that, ships with Xcode, and needs
/// no backend at all — putting it behind this interface would make the whole
/// pane unavailable whenever the backend is, which is exactly the failure the
/// capability split in `SimulatorSupport` exists to prevent.
abstract interface class SimulatorBackend {
  /// Stable identifier, for logs and for remembering a user's choice.
  String get id;

  /// What to call it in the UI when there is a choice to explain.
  String get displayName;

  /// Whether this backend can run here, right now.
  ///
  /// Cheap and side-effect free: a missing binary, an unsupported architecture,
  /// a permission not granted. Called to decide what to offer, so it must not
  /// start anything.
  Future<bool> isAvailable();

  /// Prepares the backend for [udid], if it needs preparing.
  ///
  /// Idempotent. A backend that runs a helper process starts it here rather
  /// than lazily inside the first tap, so a failure surfaces once, attached to
  /// the thing the user just asked for.
  Future<void> attach(String udid);

  /// The screen's two sizes, or null when this backend cannot say.
  Future<SimulatorScreen?> screen(String udid);

  Future<SimulatorVideoFeed> startVideo(
    String udid, {
    int fps,
    double? scale,
  });

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

  /// Whether the device is showing its lock screen.
  Future<bool> isLocked(String udid);

  /// Locks or unlocks the device.
  ///
  /// Both directions, because locking is a state and not a keypress: a button
  /// that could only ever lock leaves the user looking at a lock screen with
  /// nothing on the toolbar to undo it.
  Future<void> setLocked(String udid, {required bool locked});

  /// Opens the app switcher.
  ///
  /// Not a button, which is why it is not in [SimulatorButton]: on a device
  /// with a home indicator the switcher is a swipe up from the bottom edge that
  /// **pauses** before letting go, and on one with a physical Home button it is
  /// a double press. Neither is something a single press can express.
  Future<void> showAppSwitcher(String udid);

  /// The accessibility tree of whatever is on screen, mapped onto the same
  /// [UiHierarchy] the Android side produces so queries and taps-by-label are
  /// written once.
  Future<UiHierarchy> describeUi(String udid);

  /// Releases whatever [attach] took. Safe to call when nothing was attached.
  Future<void> detach(String udid);
}
