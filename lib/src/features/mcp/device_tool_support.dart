import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../devices/application/device_claims.dart';
import '../devices/application/device_fleet.dart';
import '../devices/application/device_screen_memory.dart';
import '../devices/domain/device_driver.dart';
import '../devices/domain/device_input.dart';
import '../devices/domain/screen_observation.dart';
import '../devices/domain/ui_node.dart';
import '../devices/domain/ui_summary.dart';

/// What reaching a device costs, written once for every `device_*` family.
///
/// The families were one class before they were five files, and these are the
/// members all of them used: the fleet, the claim, the screen memory and the
/// two ways of getting a driver. Here rather than copied into each, because a
/// second spelling of "take this device for this caller" is a second claim
/// policy, and the whole point of [DeviceClaims] is that there is only one.
///
/// Nothing here knows what kind of device it is holding — see `device_tools.dart`
/// for why that is the rule rather than an accident.
abstract class DeviceToolFamily {
  DeviceToolFamily(this.container, {this.callerSessionId});

  /// Read-only to a family: the container is how a driver, a claim and the
  /// screen memory are found, and nothing below writes to it.
  final ProviderContainer container;

  /// Which of our sessions is calling, when one is. Established by the
  /// transport, never by an argument — see `McpCallerRegistry`.
  final String? callerSessionId;

  Future<DeviceFleet> deviceFleet() => container.read(deviceFleetProvider)();

  DeviceClaims get claims => container.read(deviceClaimsProvider);

  DeviceScreenMemory get screens => container.read(deviceScreenMemoryProvider);

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

  /// The driver for a call that only **reads** this device.
  ///
  /// The capability is checked up front rather than left to fail inside the
  /// driver, so the refusal names the capability that is missing and what still
  /// works — the driver's own error would name whatever step happened to fall
  /// over first.
  ///
  /// A read renews a claim this caller already holds and never takes one, so
  /// looking at a phone somebody else is driving is always allowed. It has to
  /// be: an agent that has just been refused needs to be able to see what the
  /// holder is doing.
  Future<DeviceDriver> driverThatCan(
    String? id,
    String verb,
    DeviceCapability capability,
  ) async {
    final driver = await _driver(id, verb);
    require(driver, verb, capability);
    claims.observed(
      deviceId: driver.target.id,
      sessionId: callerSessionId,
    );
    return driver;
  }

  /// The driver for a call that will **change** this device, with the device
  /// taken for this caller — or [DeviceBusy] naming whoever is driving it.
  ///
  /// Ordered deliberately. The driver resolves first so the claim is keyed on
  /// the canonical id: two agents naming one phone two different ways
  /// (`emulator-5554` and an AVD name, a serial and a udid) must collide rather
  /// than miss each other. The capability is checked before the claim, so a
  /// device that cannot do the thing is not held while it is being told so.
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

  void require(
    DeviceDriver driver,
    String verb,
    DeviceCapability capability,
  ) {
    if (!driver.can(capability)) {
      throw DeviceRefusal('$verb: ${driver.missingReason(capability)!}');
    }
  }
}

/// Which device the caller means.
///
/// Three spellings for one argument. `serial` is what every existing Android
/// caller passes and cannot change; `udid` is what `list_devices` calls a
/// simulator's id and therefore the word an agent has in front of it when it
/// writes the next call. Accepting both costs one line and removes a class of
/// "I copied the field name out of your own output and you rejected it".
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

/// Wraps a listing as an MCP text block.
///
/// Deliberately not returned as a JSON map: the bridge pretty-prints every
/// map result, and one JSON object per node costs several times what one line
/// per node does. The whole point of this surface is that a screen fits in a
/// few hundred tokens.
Object uiTextBlock(List<String> sections) => {
  '_mcpContent': [
    {'type': 'text', 'text': sections.join('\n')},
  ],
};
