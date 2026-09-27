import 'package:karmashala_devices/karmashala_devices.dart';

import '../../devices/server_devices.dart';

/// What reaching a device costs, written once for every `device_*` family: a
/// second spelling of "take this device" is a second [DeviceClaims] policy.
abstract class DeviceToolFamily {
  DeviceToolFamily(this.devices, {this.callerSessionId});

  /// The server machine's devices, their claims and screen memory.
  final ServerDevices devices;

  /// Which session is calling, when one is. Established by the transport,
  /// never by an argument.
  final String? callerSessionId;

  Future<DeviceFleet> deviceFleet() => devices.fleet();

  DeviceClaims get claims => devices.claims.registry;

  DeviceScreenMemory get screens => devices.screens;

  /// Files a screen this call has just read, so the next coordinate tap has
  /// something to be checked against.
  ScreenObservation recordLook(DeviceDriver driver, ScreenRead read) =>
      screens.record(
        deviceId: driver.target.id,
        tree: read.tree,
        app: read.app,
        bySessionId: callerSessionId,
      );

  /// The driver for this call, or a refusal naming the device.
  Future<DeviceDriver> _driver(String? id, String verb) async =>
      (await deviceFleet()).driverFor(id, verb: verb);

  /// The driver for a call that only **reads** this device. A read renews a
  /// claim this caller already holds and never takes one, so it is never refused.
  Future<DeviceDriver> driverThatCan(
    String? id,
    String verb,
    DeviceCapability capability,
  ) async {
    final driver = await _driver(id, verb);
    require(driver, verb, capability);
    claims.observed(deviceId: driver.target.id, sessionId: callerSessionId);
    return driver;
  }

  /// The driver for a call that will **change** this device, with the device
  /// taken for this caller — or [DeviceBusy] naming whoever is driving it.
  Future<DeviceDriver> driverToDrive(
    String? id,
    String verb,
    DeviceCapability capability,
  ) async {
    final driver = await _driver(id, verb);
    require(driver, verb, capability);
    claims.claim(
      deviceId: driver.target.id,
      sessionId: callerSessionId,
      verb: verb,
    );
    return driver;
  }

  void require(DeviceDriver driver, String verb, DeviceCapability capability) {
    if (!driver.can(capability)) {
      throw DeviceRefusal('$verb: ${driver.missingReason(capability)!}');
    }
  }
}

/// Which device the caller means. Three spellings for one argument, because
/// `list_devices` prints `udid` where every Android caller passes `serial`.
String? deviceIdIn(Map<String, dynamic> args) =>
    (args['serial'] ?? args['udid'] ?? args['device']) as String?;

/// The element query `device_find_elements` and `device_tap_element` share.
UiElementQuery uiQueryIn(Map<String, dynamic> args) => UiElementQuery(
  text: args['text'] as String?,
  resourceId: args['resourceId'] as String?,
  contentDescription: args['contentDesc'] as String?,
  className: args['className'] as String?,
  exact: args['exact'] == true,
  clickableOnly: args['clickable'] == true,
);

/// One line naming the device, the foreground app and the coordinate space.
String uiHeader(DeviceDriver driver, ScreenRead read) =>
    '${driver.target.id} · ${read.app ?? 'unknown app'} · '
    'screen ${read.screen ?? 'unknown'} ${read.space.label} · '
    'rotation ${read.tree.rotation}';

/// The coordinate space, said once per listing where it cannot be missed.
String spaceLine(ScreenRead read) => read.space == CoordinateSpace.points
    ? 'Coordinates are in POINTS, which is what device_tap and '
          'device_tap_element take on this device — NOT the pixels a '
          'device_screenshot image is in.'
    : 'Coordinates are in device pixels.';

/// The matches numbered, so the caller can pass `index`.
String indexedMatches(List<UiNode> matches, DeviceScreenSize? screen) => [
  for (var i = 0; i < matches.length && i < 20; i++)
    '[$i] ${describeUiNode(matches[i], screen: screen)}',
].join('\n');

/// Wraps a listing as an MCP text block, not a JSON map: the bridge
/// pretty-prints maps, and one object per node costs several times one line.
Object uiTextBlock(List<String> sections) => {
  '_mcpContent': [
    {'type': 'text', 'text': sections.join('\n')},
  ],
};
