import '../../devices/server_devices.dart';
import 'device_app_tools.dart';
import 'device_drive_tools.dart';
import 'device_file_tools.dart';
import 'device_inventory_tools.dart';
import 'device_observe_tools.dart';
import 'device_state_tools.dart';
import 'server_tool_set.dart';

// The policy is quoted by tests and by anything explaining the two taps, and
// this file is the door they come to.
export 'device_drive_tools.dart' show kDeviceLocatingPolicy;

/// `list_devices` and the `device_*` tools (slice 4a): an Android device, an
/// emulator or an iOS Simulator **on the server's machine**, driven end to end
/// by the server with every client closed. One family; the id says which
/// device. Recording (`device_record_start/stop`) needs a live view and stays
/// a client's until slice 4b.
class DeviceToolSet extends ServerToolSet {
  DeviceToolSet(this.devices);

  final ServerDevices devices;

  @override
  List<Map<String, Object?>> get schemas => deviceToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() {
    if (DeviceInventoryTools.handles(tool)) {
      return DeviceInventoryTools(
        devices,
        callerSessionId: callerSessionId,
      ).call(tool, arguments);
    }
    if (DeviceObserveTools.handles(tool)) {
      return DeviceObserveTools(
        devices,
        callerSessionId: callerSessionId,
      ).call(tool, arguments);
    }
    if (DeviceDriveTools.handles(tool)) {
      return DeviceDriveTools(
        devices,
        callerSessionId: callerSessionId,
      ).call(tool, arguments);
    }
    if (DeviceAppTools.handles(tool)) {
      return DeviceAppTools(
        devices,
        callerSessionId: callerSessionId,
      ).call(tool, arguments);
    }
    if (DeviceFileTools.handles(tool)) {
      return DeviceFileTools(
        devices,
        callerSessionId: callerSessionId,
      ).call(tool, arguments);
    }
    if (DeviceStateTools.handles(tool)) {
      return DeviceStateTools(
        devices,
        callerSessionId: callerSessionId,
      ).call(tool, arguments);
    }
    throw ArgumentError('Unknown tool: $tool');
  });
}

/// The schemas for [DeviceToolSet], in the order they are served — unchanged
/// from the app's (its golden only reorders).
const List<Map<String, Object?>> deviceToolSchemas = [
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
  deviceOpenUrlSchema,
  deviceSetStateSchema,
  deviceAppPermissionSchema,
  deviceClearAppDataSchema,
];
