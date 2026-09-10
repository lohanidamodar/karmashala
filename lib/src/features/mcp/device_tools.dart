import 'package:riverpod/riverpod.dart';

import 'device_app_tools.dart';
import 'device_drive_tools.dart';
import 'device_file_tools.dart';
import 'device_inventory_tools.dart';
import 'device_observe_tools.dart';

// The policy is quoted by tests and by anything explaining the two taps, and
// this file is the door they come to. Nothing else here is re-exported.
export 'device_drive_tools.dart' show kDeviceLocatingPolicy;

/// An Android device, an emulator or an iOS Simulator, driven end to end
/// through the device pane's own services. One family; the id says which.
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

/// The schemas for [DeviceControlTools], in the order they are served — pinned
/// byte for byte by `tool_schemas_golden_test.dart`.
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
