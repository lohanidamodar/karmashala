import 'package:karmashala/src/features/mcp/device_tools.dart';
import 'package:karmashala/src/features/mcp/instructions_tools.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// The locating policy is only a policy if an agent meets it while choosing.
///
/// These assert on the served text rather than on the constant, because a rule
/// stated in a file nothing reads is the thing this change exists to stop.

/// The description `tools/list` serves for [name].
String _description(String name) => LauncherControlServer.toolSchemas
    .firstWhere(
      (schema) => schema['name'] == name,
      orElse: () => throw StateError('no schema for $name'),
    )['description']!
    as String;

void main() {
  group('the policy is on the tools it governs', () {
    test('all four state it, in the same words', () {
      for (final name in <String>[
        'device_tap',
        'device_tap_element',
        'device_find_elements',
        'device_ui_dump',
      ]) {
        expect(
          _description(name),
          contains(kDeviceLocatingPolicy),
          reason: '$name does not state the locating policy',
        );
      }
    });

    test('it says which to prefer, and when the fallback is allowed', () {
      expect(kDeviceLocatingPolicy, contains('Prefer device_tap_element'));
      expect(
        kDeviceLocatingPolicy,
        contains('only when the dynamic attempt has failed'),
      );
      expect(
        kDeviceLocatingPolicy,
        contains('coordinates you verified during exploration'),
      );
    });

    test('and closes the speed argument, which is what changes a choice', () {
      // "Prefer the robust thing" loses to "the other one is faster" unless
      // the other one is not.
      expect(
        kDeviceLocatingPolicy,
        contains('no speed reason to skip the dynamic path'),
      );
      expect(kDeviceLocatingPolicy, contains('the two cost the same'));
    });

    test('device_tap says what it now refuses and how to opt out', () {
      final tap = _description('device_tap');
      expect(tap, contains('refuses when the structure has changed'));
      expect(tap, contains('verify: false'));
    });
  });

  group('the devices guide', () {
    final devices = kMcpGuides.firstWhere((guide) => guide.topic == 'devices');

    test('states the rule, not merely a preference', () {
      expect(devices.body, contains('Dynamic first, coordinates as a checked'));
      expect(
        devices.body,
        contains('only when the dynamic attempt has failed'),
      );
      expect(devices.body, contains('verified during exploration'));
    });

    test('states the speed argument', () {
      expect(
        devices.body,
        contains('no speed reason to skip the dynamic path'),
      );
    });

    test('states the safety net and the way past it', () {
      expect(devices.body, contains('reads the\nscreen once immediately'));
      expect(devices.body, contains('verify: false'));
    });

    test('states the lock, and that reading is never blocked', () {
      expect(devices.body, contains('One task per device'));
      expect(devices.body, contains('Reading is never\nblocked'));
      expect(devices.body, contains('lapses on its own'));
    });
  });
}
