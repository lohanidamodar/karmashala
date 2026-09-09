import '../devices/domain/device_driver.dart';
import 'device_tool_support.dart';

/// An app on a device: put it there, start it, stop it.
///
/// The three verbs an agent needs between building something and looking at
/// it. Each one changes the device, so each takes the claim — see
/// [DeviceToolFamily.driverToDrive].
class DeviceAppTools extends DeviceToolFamily {
  DeviceAppTools(super.container, {super.callerSessionId});

  static const Set<String> _names = <String>{
    'device_install_app',
    'device_launch_app',
    'device_terminate_app',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'device_install_app' => _deviceInstallApp(
          id: deviceIdIn(args),
          path: args['path'] as String?,
        ),
        'device_launch_app' => _deviceLaunchApp(
          id: deviceIdIn(args),
          appId: args['appId'] as String?,
          activity: args['activity'] as String?,
          relaunch: args['relaunch'] == true,
        ),
        'device_terminate_app' => _deviceTerminateApp(
          id: deviceIdIn(args),
          appId: args['appId'] as String?,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Future<Object?> _deviceInstallApp({String? id, String? path}) async {
    if (path == null || path.trim().isEmpty) {
      throw ArgumentError(
        'path is required: an .apk for Android, or a simulator .app bundle for '
        'iOS.',
      );
    }
    final driver = await driverToDrive(
      id,
      'device_install_app',
      DeviceCapability.installApp,
    );
    final installed = await driver.installApp(path.trim());
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'installed': installed.path,
      'appId': ?installed.appId,
      'note': ?installed.note,
    };
  }

  Future<Object?> _deviceLaunchApp({
    String? id,
    String? appId,
    String? activity,
    bool relaunch = false,
  }) async {
    if (appId == null || appId.trim().isEmpty) {
      throw ArgumentError(
        'appId is required: an Android applicationId (com.example.app) or an '
        'iOS bundle id (com.example.App).',
      );
    }
    final driver = await driverToDrive(
      id,
      'device_launch_app',
      DeviceCapability.appLifecycle,
    );
    final launched = await driver.launchApp(
      appId.trim(),
      activity: activity,
      relaunch: relaunch,
    );
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'launched': launched.appId,
      'pid': ?launched.pid,
      'note':
          'Give it a moment to draw, then read it with device_ui_dump.'
          '${launched.note == null ? '' : ' ${launched.note}'}',
    };
  }

  Future<Object?> _deviceTerminateApp({String? id, String? appId}) async {
    if (appId == null || appId.trim().isEmpty) {
      throw ArgumentError('appId is required.');
    }
    final driver = await driverToDrive(
      id,
      'device_terminate_app',
      DeviceCapability.appLifecycle,
    );
    await driver.terminateApp(appId.trim());
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'terminated': appId.trim(),
      // Both platforms treat "it was not running" as success, and saying so is
      // the difference between a caller trusting this reply and a caller
      // re-checking with a UI dump.
      'note':
          'An app that was not running is not an error — this asks for a '
          'state, and reports the state it left behind.',
    };
  }
}

/// The schemas for [DeviceAppTools].
const Map<String, dynamic> deviceInstallAppSchema = {
  'name': 'device_install_app',
  'description':
      'Install a build onto a device or simulator: an .apk on Android '
      '(reinstalling over any existing copy and keeping its data), or a '
      'simulator .app bundle on iOS. This is what turns build-run-drive into '
      'one loop. An .ipa is refused — it carries the device slice, and a '
      'simulator needs the simulator slice (flutter build ios --simulator). '
      'On iOS the reply carries the bundle id read out of the bundle, ready '
      'for device_launch_app; on Android adb does not report one, so pass '
      'your applicationId.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'path': {
        'type': 'string',
        'description':
            'Absolute path to the .apk or the .app bundle directory.',
      },
    },
    'required': ['path'],
  },
};

const Map<String, dynamic> deviceLaunchAppSchema = {
  'name': 'device_launch_app',
  'description':
      'Launch an installed app by Android applicationId or iOS bundle id. On '
      'Android the launcher activity is resolved for you; pass activity to '
      'start a specific one instead. On iOS pass relaunch=true to terminate '
      'any running copy first, which is what makes it a cold start rather '
      'than a switch to the front.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'appId': {
        'type': 'string',
        'description': 'com.example.app (Android) or com.example.App (iOS).',
      },
      'activity': {
        'type': 'string',
        'description':
            'Android only. Activity to start, e.g. .MainActivity. Refused on '
            'iOS, which has no activities.',
      },
      'relaunch': {
        'type': 'boolean',
        'description': 'iOS only. Terminate a running copy first.',
      },
    },
    'required': ['appId'],
  },
};

const Map<String, dynamic> deviceTerminateAppSchema = {
  'name': 'device_terminate_app',
  'description':
      'Stop a running app — force-stop on Android, simctl terminate on a '
      'simulator. An app that was not running is not an error.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'appId': {'type': 'string'},
    },
    'required': ['appId'],
  },
};
