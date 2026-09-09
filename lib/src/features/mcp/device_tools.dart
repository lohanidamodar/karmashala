import 'package:riverpod/riverpod.dart';

import 'device_app_tools.dart';
import 'device_drive_tools.dart';
import 'device_file_tools.dart';
import 'device_inventory_tools.dart';
import 'device_observe_tools.dart';

// The policy is quoted by tests and by anything explaining the two taps, and
// this file is the door they come to. Nothing else here is re-exported: a
// family is imported by name.
export 'device_drive_tools.dart' show kDeviceLocatingPolicy;

/// An attached Android device, an Android emulator, or an iOS Simulator, as an
/// agent can drive it end to end: list, boot, install, launch, tap, read back.
///
/// Everything goes through the same services the device pane uses, so the agent
/// and the person beside it are looking at and touching one device rather than
/// two views of it.
///
/// ## One vocabulary, not two
///
/// These tools were Android-only, and every one of them took a `serial`. Adding
/// simulators could have meant a `simulator_*` family beside them — but
/// `device_tap` and `simulator_tap` are the same verb applied to the same kind
/// of object, and splitting them makes "which family do I call" a question the
/// agent has to answer *before* it knows what it is holding. The identifiers
/// give nothing away: `emulator-5554` and `70592006-11CD-…` are both just
/// strings that came out of `list_devices`.
///
/// So there is one family, the id is the discriminator, and `DeviceFleet` does
/// the dispatch. Every existing Android caller keeps working unchanged, because
/// an Android serial still resolves to exactly what it always did.
///
/// ## Nothing in this file knows what kind of device it is holding
///
/// ## Nothing in this family knows what kind of device it is holding
///
/// Every handler in the five files below resolves a `DeviceDriver` and then
/// speaks only that interface. There is no `if (isSimulator)` anywhere, and
/// adding one would be the bug: the engine behind a simulator has already been
/// swapped once — idb out, WebDriverAgent in — and a `CoreSimulator` or
/// `pymobiledevice3` driver should cost this family nothing. The only place
/// that names a platform is `list_devices`, which is a *listing* and whose
/// whole job is to say which is which.
///
/// ## A tool never pretends
///
/// Two mechanisms, both of them checked before anything is attempted:
/// `DeviceCapability`, for what a driver cannot do at all, and `DeviceRefusal`,
/// for what it cannot do with these particular arguments. Either way the caller
/// gets a sentence naming the device, the thing that is missing, and what still
/// works. An agent has no eyes, so a verb that quietly does nothing reads to it
/// as a verb that worked.
///
/// Lifted out of `LauncherControlServer` unchanged. It was the largest family
/// still inline there, and the seam was already drawn — the terminal, browser,
/// workspace and verification tools had each been given a file of their own,
/// and the device tools' only tie to the server was the container they read
/// providers from.
///
/// ## One task per device
///
/// Everything that changes a device goes through `DeviceClaims` first, so two
/// agents cannot interleave taps on one phone. Everything that only *reads* one
/// goes through it too, but only to say the holder is still working — a read
/// never takes a claim and is never refused. See `device_claim.dart` for why a
/// device gets a lock when a repository deliberately does not.
///
/// ## Five files, one door
///
/// The nineteen tools are grouped by what they do to a device, and this class
/// is only the manifest: it says which family answers a name and hands the call
/// on. `device_tool_support.dart` holds what all five need.
class DeviceControlTools {
  DeviceControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which of our sessions is calling, when one is. Established by the
  /// transport, never by an argument — see `McpCallerRegistry`.
  final String? callerSessionId;

  late final _inventory = DeviceInventoryTools(
    _container,
    callerSessionId: callerSessionId,
  );
  late final _observe = DeviceObserveTools(
    _container,
    callerSessionId: callerSessionId,
  );
  late final _drive = DeviceDriveTools(
    _container,
    callerSessionId: callerSessionId,
  );
  late final _app = DeviceAppTools(_container, callerSessionId: callerSessionId);
  late final _file = DeviceFileTools(
    _container,
    callerSessionId: callerSessionId,
  );

  static bool handles(String name) =>
      DeviceInventoryTools.handles(name) ||
      DeviceObserveTools.handles(name) ||
      DeviceDriveTools.handles(name) ||
      DeviceAppTools.handles(name) ||
      DeviceFileTools.handles(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async {
    if (DeviceInventoryTools.handles(name)) return _inventory.call(name, args);
    if (DeviceObserveTools.handles(name)) return _observe.call(name, args);
    if (DeviceDriveTools.handles(name)) return _drive.call(name, args);
    if (DeviceAppTools.handles(name)) return _app.call(name, args);
    if (DeviceFileTools.handles(name)) return _file.call(name, args);
    throw ArgumentError('Unknown tool: $name');
  }
}

/// The schemas for [DeviceControlTools], in the order they are served.
///
/// One entry per tool rather than five family lists spread in turn, because
/// the served order interleaves the families and it is the order an MCP client
/// sees — pinned, byte for byte, by `tool_schemas_golden_test.dart`.
const List<Map<String, dynamic>> deviceControlToolSchemas = [
  listDevicesSchema,
  deviceScreenshotSchema,
  deviceTapSchema,
  deviceTypeSchema,
  deviceKeySchema,
  deviceFilesListSchema,
  deviceFilePullSchema,
  deviceFilePushSchema,
  deviceLogcatSchema,
  deviceBootSchema,
  deviceInstallAppSchema,
  deviceLaunchAppSchema,
  deviceTerminateAppSchema,
  deviceStopEmulatorSchema,
  deviceUiDumpSchema,
  deviceFindElementsSchema,
  deviceTapElementSchema,
];
