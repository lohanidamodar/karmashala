import 'dart:typed_data';

import 'device_input.dart';
import 'device_target.dart';
import 'ui_node.dart';

/// Something a device can be asked to do, so that a device which cannot do it
/// can say so instead of pretending.
///
/// The same idea as `SimulatorCapability` in `ios_device_providers.dart`, which
/// exists because a simulator pane reporting one "supported" bit would either
/// hide everything that works or offer taps that silently do nothing. The same
/// trap is worse here: an agent has no eyes, so a verb that quietly no-ops
/// reads to it as a verb that worked.
///
/// Coarser than the method list on purpose. These are the lines along which
/// support actually breaks — a build with no WebDriverAgent loses touch, typing
/// and the element tree *together*, because they are one runner — and a
/// capability per method would suggest they could be missing separately.
enum DeviceCapability {
  /// Taps, swipes and typing.
  input,

  /// Hardware buttons. Separate from [input] because the sets differ: iOS has
  /// two buttons where Android has nine, and [DeviceDriver.pressKey] refuses
  /// the individual ones it lacks.
  keys,

  /// The accessibility tree — what is on screen and where to hit it.
  uiTree,

  screenshot,

  /// A readable device log.
  logs,

  /// Putting a build onto the device.
  installApp,

  /// Launching and terminating an installed app.
  appLifecycle,

  /// Shutting the device down. Virtual devices only: nothing here turns off
  /// somebody's physical phone.
  powerOff,
}

/// A device refusing, by name, with the reason.
///
/// Its own type rather than a [StateError] so a refusal reads as a sentence in
/// an agent's transcript — `StateError.toString()` prefixes "Bad state:", which
/// suggests this app broke rather than that the device cannot do the thing.
class DeviceRefusal implements Exception {
  const DeviceRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Which numbers a device's coordinates are in.
///
/// Carried everywhere rather than assumed, because the difference is invisible
/// in the numbers themselves: `(201, 437)` is a plausible point on either kind
/// of device and only one of them is right. Android reports and accepts device
/// **pixels**; WebDriverAgent reports element frames and accepts taps in
/// **points** — an iPhone 17 Pro is 402x874 points on a 1206x2622 pixel screen,
/// so using the wrong one puts a tap three times too far down and to the right,
/// off the screen, while the call still reports success.
enum CoordinateSpace {
  devicePixels('device px'),
  points('points');

  const CoordinateSpace(this.label);

  final String label;
}

/// One read of what is on a screen, in the space that device uses.
class ScreenRead {
  const ScreenRead({
    required this.tree,
    required this.screen,
    required this.space,
    required this.app,
  });

  final UiHierarchy tree;

  /// The screen, in [space]. Null when the device would not say.
  final DeviceScreenSize? screen;

  final CoordinateSpace space;

  /// The foreground app: a package name on Android, a bundle id on iOS.
  final String? app;
}

/// A captured screen, and the honest name of the space its pixels are in.
class DeviceScreenshot {
  const DeviceScreenshot({
    required this.bytes,
    required this.size,
    required this.imageSpace,
    required this.tapSpace,
  });

  final Uint8List bytes;

  /// The image's own size, in [imageSpace].
  final DeviceScreenSize? size;

  /// What the picture is measured in.
  final CoordinateSpace imageSpace;

  /// What a tap on this device is measured in.
  ///
  /// Held beside [imageSpace] because on a simulator **they differ** — the
  /// capture is the pixel backing store and the tap is in points — and a
  /// coordinate read off the image is then wrong by the display scale. Android
  /// is the easy case where both are pixels, and the type does not hide that
  /// iOS is not.
  final CoordinateSpace tapSpace;

  bool get spacesAgree => imageSpace == tapSpace;
}

/// What a log read produced, with anything the caller should know about how it
/// was filtered.
class DeviceLogRead {
  const DeviceLogRead({required this.lines, this.note});

  final List<String> lines;

  /// A sentence when the filtering did something other than what was asked —
  /// see the iOS driver, where `package` is a substring match and says so.
  final String? note;
}

/// What an install left behind.
class InstalledApp {
  const InstalledApp({required this.path, this.appId, this.note});

  final String path;

  /// The id to launch it by, when the driver could read it out of the artifact.
  /// Null is normal on Android, where adb does not report what an APK declares.
  final String? appId;

  final String? note;
}

/// What a launch produced.
class LaunchedApp {
  const LaunchedApp({required this.appId, this.pid, this.note});

  final String appId;

  /// The process id, when the platform reported one.
  final int? pid;

  final String? note;
}

/// How a key press was actually delivered, for a reply that does not overstate
/// what happened — "the home button" is not the same event as "typed into the
/// focused field", and a caller debugging a flow needs to know which it got.
class KeyPress {
  const KeyPress({required this.key, required this.how});

  final DeviceKey key;
  final String how;
}

/// Everything the `device_*` tools can do to one device, whatever it is.
///
/// **This interface exists so the thing behind it can be replaced**, and so
/// that nothing above it has to ask what kind of device it is holding. The
/// callers resolve a driver from an id once and then speak only this — there is
/// no `if (isSimulator)` in the tool layer.
///
/// It sits *on top of* the existing seams rather than replacing them. The iOS
/// driver composes `SimctlService` with `SimulatorBackend`, and
/// `SimulatorBackend` keeps its own doc-comment promise: swap WebDriverAgent
/// for a CoreSimulator-based engine and only that one interface has to be
/// satisfied. The Android driver wraps `AdbService` the same way.
///
/// **A driver never silently no-ops.** Anything it cannot do is either absent
/// from [capabilities] — with [missingReason] saying why — or throws
/// [DeviceRefusal] naming itself and the reason. Both are checked by the tools
/// before the call and reported to the caller verbatim.
abstract interface class DeviceDriver {
  /// Stable identifier for the engine, for logs and for messages: `adb`,
  /// `simctl+wda`. Names the *driver*, not the device.
  String get id;

  /// What to call the engine in a refusal.
  String get displayName;

  /// The device this driver is bound to. A driver is per-device rather than
  /// per-platform, because every call it makes needs the id anyway and
  /// threading it through each method invites passing the wrong one.
  DeviceTarget get target;

  Set<DeviceCapability> get capabilities;

  bool can(DeviceCapability capability) => capabilities.contains(capability);

  /// Why [capability] is missing, as a sentence for the caller. Must be
  /// non-null for every capability this driver does not have, and must name
  /// what still works — an agent that reads "unsupported" concludes the whole
  /// platform is a dead end, when usually only one verb is.
  String? missingReason(DeviceCapability capability);

  /// The space [tap] takes and [describeScreen] reports.
  CoordinateSpace get coordinateSpace;

  Future<DeviceScreenshot> screenshot();

  Future<ScreenRead> describeScreen();

  /// Taps a point in [coordinateSpace].
  Future<void> tap(int x, int y);

  Future<void> type(String text);

  /// Presses a hardware key, or refuses with [DeviceRefusal] for one this
  /// device does not have. The refusal is per-key rather than a capability,
  /// because a device that has *some* of them is the normal case.
  Future<KeyPress> pressKey(DeviceKey key);

  /// Recent log lines, newest last.
  ///
  /// [filter] and [level] are honestly named as what they are on Android and
  /// documented per driver: the iOS driver refuses [level] rather than mapping
  /// two different ladders onto each other, and says in [DeviceLogRead.note]
  /// that its [filter] is a substring match.
  Future<DeviceLogRead> readLog({String? filter, String? level, int lines});

  /// Installs a build. [path] is an `.apk` or a simulator `.app` bundle; a
  /// driver handed the other platform's artifact refuses by name rather than
  /// letting the tool underneath fail with an architecture error.
  Future<InstalledApp> installApp(String path);

  /// Launches an installed app.
  ///
  /// [appId] is an Android applicationId or an iOS bundle id — the same kind of
  /// thing under two names, which is why one parameter is honest here.
  /// [activity] is **not**: Android can start one of several entry points and
  /// iOS has exactly one, so it is named for what it is and the iOS driver
  /// refuses it rather than accepting and ignoring it. [relaunch] is the
  /// mirror image, an iOS switch with no Android equivalent.
  Future<LaunchedApp> launchApp(
    String appId, {
    String? activity,
    bool relaunch,
  });

  Future<void> terminateApp(String appId);

  /// Shuts the device down. Only meaningful for a virtual device — see
  /// [DeviceCapability.powerOff].
  ///
  /// Returns a sentence describing what was left behind, because the two
  /// platforms differ in a way that matters: an emulator loses anything not in
  /// a snapshot, a simulator keeps its apps and data.
  Future<String> powerOff();
}
