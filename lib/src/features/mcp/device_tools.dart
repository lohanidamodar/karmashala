import 'package:riverpod/riverpod.dart';

import 'device_app_tools.dart';
import 'device_drive_tools.dart';
import 'device_file_tools.dart';
import 'device_inventory_tools.dart';
import 'device_observe_tools.dart';

// The policy is quoted by tests and by anything explaining the two taps, and
// this file is the door they come to. Nothing else here is re-exported.
export 'device_drive_tools.dart' show kDeviceLocatingPolicy;

/// An attached Android device, an Android emulator, or an iOS Simulator, as an
/// agent can drive it end to end — through the same services the device pane
/// uses, so the agent and the person beside it touch one device.
///
/// **One family, and the id is the discriminator**: a `simulator_*` family
/// would make "which do I call" a question an agent has to answer before it
/// knows what it is holding. Nothing below knows what kind of device it holds
/// except `list_devices`, whose whole job is to say which is which.
///
/// A tool never pretends: `DeviceCapability` and `DeviceRefusal` are checked
/// before anything is attempted, because an agent has no eyes and a verb that
/// quietly does nothing reads as one that worked. Anything that changes a device
/// takes a `DeviceClaims` claim first; a read never does.
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

/// The schemas for [DeviceControlTools], in the order they are served. One
/// entry per tool rather than five family lists, because the served order
/// interleaves the families and is pinned byte for byte by
/// `tool_schemas_golden_test.dart`.
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
