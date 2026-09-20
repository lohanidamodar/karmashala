import 'dart:typed_data';

import 'device_files.dart';
import 'device_input.dart';
import 'device_target.dart';
import 'ui_node.dart';

/// Something a device can be asked to do, so that a device which cannot do it
/// can say so instead of pretending. Coarser than the method list on purpose:
/// these are the lines along which support actually breaks.
enum DeviceCapability {
  /// Taps, swipes and typing.
  input,

  /// Hardware buttons. Separate from [input] because the sets differ, and
  /// [DeviceDriver.pressKey] refuses the individual ones it lacks.
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

  /// Reaching the device's storage: listing, and moving files both ways. One
  /// capability for six methods — they are one transport and break together.
  files,
}

/// A device refusing, by name, with the reason. Its own type so a refusal reads
/// as a sentence: `StateError` prefixes "Bad state:", which blames this app.
class DeviceRefusal implements Exception {
  const DeviceRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Which numbers a device's coordinates are in. Carried rather than assumed:
/// Android reports pixels and WebDriverAgent points, and a tap in the wrong one
/// lands off screen while the call still reports success.
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

  /// What a tap on this device is measured in. On a simulator it differs from
  /// [imageSpace], so a coordinate read off the image is off by the scale.
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

/// How a key press was actually delivered — "the home button" is not the same
/// event as "typed into the focused field".
class KeyPress {
  const KeyPress({required this.key, required this.how});

  final DeviceKey key;
  final String how;
}

/// Everything the `device_*` tools can do to one device, whatever it is, so
/// nothing above has to ask what kind it is holding. **A driver never silently
/// no-ops:** it refuses by name, or lacks the capability with a reason.
abstract interface class DeviceDriver {
  /// Stable identifier for the engine, for logs and for messages: `adb`,
  /// `simctl+wda`. Names the *driver*, not the device.
  String get id;

  /// What to call the engine in a refusal.
  String get displayName;

  /// The device this driver is bound to. Per-device rather than per-platform, so
  /// no call has to thread an id that could be the wrong one.
  DeviceTarget get target;

  Set<DeviceCapability> get capabilities;

  bool can(DeviceCapability capability) => capabilities.contains(capability);

  /// Why [capability] is missing, as a sentence, and it must name what still
  /// works: an agent reading "unsupported" writes the whole platform off.
  String? missingReason(DeviceCapability capability);

  /// The space [tap] takes and [describeScreen] reports.
  CoordinateSpace get coordinateSpace;

  Future<DeviceScreenshot> screenshot();

  Future<ScreenRead> describeScreen();

  /// Taps a point in [coordinateSpace].
  Future<void> tap(int x, int y);

  Future<void> type(String text);

  /// Presses a hardware key, or throws [DeviceRefusal] for one this device does
  /// not have. Per-key rather than a capability: partial support is normal.
  Future<KeyPress> pressKey(DeviceKey key);

  /// Recent log lines, newest last. [filter] and [level] are named for what they
  /// are on Android; the iOS driver refuses [level] rather than approximating.
  Future<DeviceLogRead> readLog({String? filter, String? level, int lines});

  /// Installs a build. A driver handed the other platform's artifact refuses by
  /// name rather than letting the tool underneath fail on architecture.
  Future<InstalledApp> installApp(String path);

  /// Launches an installed app. [activity] is Android-only and [relaunch]
  /// iOS-only; the other driver refuses each rather than ignoring it.
  Future<LaunchedApp> launchApp(
    String appId, {
    String? activity,
    bool relaunch,
  });

  Future<void> terminateApp(String appId);

  /// Shuts the device down; virtual devices only. Returns a sentence about what
  /// was left behind: an emulator loses what a simulator keeps.
  Future<String> powerOff();

  /// The places on this device a browser can start from — **not "the root"**: a
  /// real iPhone has none to return. Refuses rather than answering empty.
  Future<List<DeviceFileRoot>> fileRoots();

  /// Lists one directory. Throws [DeviceRefusal] rather than **ever returning an
  /// empty listing for a refusal**; unparsed rows come back in `skipped`.
  Future<DeviceDirectoryListing> listDirectory(String path);

  /// What [path] is, or null when nothing is there. Null means *absent*; a path
  /// that exists but cannot be read throws, because callers act oppositely.
  Future<DeviceFileEntry?> stat(String path);

  /// Copies a file off the device onto this computer.
  Future<DeviceFileTransfer> pullFile({
    required String devicePath,
    required String hostPath,
  });

  /// Copies a file from this computer onto the device. [devicePath] is the
  /// destination *file*. **[overwrite] defaults to false**: there is no undo.
  Future<DeviceFileTransfer> pushFile({
    required String hostPath,
    required String devicePath,
    bool overwrite,
  });

  /// Copies or moves a path **within** the device, with no host round trip.
  /// [overwrite] defaults to false, and a [move] onto its own path is refused.
  Future<DeviceFileTransfer> copyWithinDevice({
    required String from,
    required String to,
    bool move,
    bool overwrite,
  });

  /// Removes a file or directory. Not undoable, anywhere, ever. [recursive] is
  /// required for a non-empty directory and refused rather than assumed.
  Future<void> deletePath(String path, {bool recursive});
}
