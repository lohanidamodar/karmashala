import 'package:karmashala_devices/karmashala_devices.dart';

import 'device_tool_support.dart';

/// What the system tells an app under test: a link, appearance, font scale,
/// locale, rotation, network, a permission, its data. Every one changes the
/// device, so every one takes the claim; each platform refuses by name.
class DeviceStateTools extends DeviceToolFamily {
  DeviceStateTools(super.devices, {super.callerSessionId});

  static const Set<String> _names = <String>{
    'device_open_url',
    'device_set_state',
    'device_app_permission',
    'device_clear_app_data',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'device_open_url' => _single(
          args,
          name,
          OpenUrlChange(
            _required(args, 'url', 'a https:// link or a custom scheme'),
            appId: _optional(args, 'appId'),
          ),
        ),
        'device_set_state' => _setState(args),
        'device_app_permission' => _single(
          args,
          name,
          PermissionChange(
            appId: _required(args, 'appId', 'the application or bundle id'),
            permission: _required(args, 'permission', 'CAMERA, or photos'),
            grant: switch (_optional(args, 'action')) {
              'grant' => true,
              'revoke' => false,
              _ => throw ArgumentError('action is required: grant or revoke.'),
            },
          ),
        ),
        'device_clear_app_data' => _single(
          args,
          name,
          ClearAppDataChange(
            _required(args, 'appId', 'the application or bundle id'),
          ),
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Future<Object?> _single(
    Map<String, dynamic> args,
    String verb,
    DeviceStateChange change,
  ) async {
    final driver = await driverToDrive(
      deviceIdIn(args),
      verb,
      DeviceCapability.deviceState,
    );
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'done': await driver.changeState(change),
    };
  }

  /// Each setting asked for, in a fixed order, each reported on its own: one
  /// refusal does not undo or hide the others.
  Future<Object?> _setState(Map<String, dynamic> args) async {
    final changes = <DeviceStateChange>[
      if (_optional(args, 'appearance') case final appearance?)
        switch (appearance) {
          'dark' => const AppearanceChange(dark: true),
          'light' => const AppearanceChange(dark: false),
          _ => throw ArgumentError('appearance is "light" or "dark".'),
        },
      if (args['fontScale'] case final num scale)
        FontScaleChange(scale.toDouble()),
      if (_optional(args, 'locale') case final locale?)
        LocaleChange(locale, appId: _optional(args, 'appId')),
      if (_optional(args, 'rotation') case final rotation?)
        RotationChange(
          DeviceRotation.fromName(rotation) ??
              (throw ArgumentError(
                'rotation is one of '
                '${DeviceRotation.values.map((r) => r.name).join(', ')}.',
              )),
        ),
      if (_optional(args, 'network') case final network?)
        NetworkChange(
          NetworkProfile.fromName(network) ??
              (throw ArgumentError(
                'network is one of '
                '${NetworkProfile.values.map((n) => n.name).join(', ')}.',
              )),
        ),
    ];
    if (changes.isEmpty) {
      throw ArgumentError(
        'Nothing to set: pass at least one of appearance, fontScale, locale, '
        'rotation or network.',
      );
    }
    final driver = await driverToDrive(
      deviceIdIn(args),
      'device_set_state',
      DeviceCapability.deviceState,
    );
    final done = <String, String>{};
    final refused = <String, String>{};
    for (final change in changes) {
      try {
        done[change.key] = await driver.changeState(change);
      } on DeviceRefusal catch (refusal) {
        refused[change.key] = refusal.message;
      } on StateError catch (error) {
        refused[change.key] = error.message;
      }
    }
    if (done.isEmpty) {
      throw DeviceRefusal(
        'NOTHING WAS CHANGED on ${driver.target.id}. '
        '${refused.entries.map((e) => '${e.key}: ${e.value}').join(' ')}',
      );
    }
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'done': done,
      if (refused.isNotEmpty) 'refused': refused,
    };
  }

  static String? _optional(Map<String, dynamic> args, String key) {
    final value = (args[key] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String _required(Map<String, dynamic> args, String key, String what) =>
      _optional(args, key) ?? (throw ArgumentError('$key is required: $what.'));
}

const Map<String, Object?> _deviceProperties = {
  'serial': {'type': 'string'},
  'udid': {'type': 'string', 'description': 'Alias for serial.'},
};

/// The schemas for [DeviceStateTools].
const Map<String, Object?> deviceOpenUrlSchema = {
  'name': 'device_open_url',
  'description':
      'Open a URL on a device or simulator — a web link, an app link, or a '
      'custom-scheme deep link such as myapp://orders/42. Use it to land an '
      'app on a screen without tapping your way there. On Android pass appId '
      'to send the link to one app rather than whichever claims it; iOS '
      'routes by scheme alone and refuses appId. A link no app handles is an '
      'error, not a silent success. Read the screen afterwards: opening is '
      'not arriving.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      ..._deviceProperties,
      'url': {'type': 'string'},
      'appId': {
        'type': 'string',
        'description': 'Android only: the applicationId to deliver it to.',
      },
    },
    'required': ['url'],
  },
};

const Map<String, Object?> deviceSetStateSchema = {
  'name': 'device_set_state',
  'description':
      'Change what the system tells the app under test: appearance, font '
      'scale, locale, rotation and network. Pass only the ones you want; each '
      'is reported on its own under done or refused, and one refusal leaves '
      'the others applied. What each platform can do — Android: all five, '
      'but locale only per app (Android 13+, needs appId; the system locale '
      'needs root), and network throttling (lte, umts, edge, gprs) only on an '
      'emulator; a phone can only go offline or full. iOS Simulator: '
      'appearance, font scale (snapped to the nearest Dynamic Type '
      'category) and locale (the app must be relaunched); rotation and '
      'network are refused — simctl cannot do them. Every change persists '
      'until changed back.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      ..._deviceProperties,
      'appearance': {
        'type': 'string',
        'enum': ['light', 'dark'],
      },
      'fontScale': {
        'type': 'number',
        'description': '1.0 is the default; 0.5–3.5.',
      },
      'locale': {
        'type': 'string',
        'description': 'A BCP 47 tag: "fr", "fr-FR", "ar-EG".',
      },
      'appId': {
        'type': 'string',
        'description': 'Android: the app whose locale to set. Required there.',
      },
      'rotation': {
        'type': 'string',
        'enum': [
          'auto',
          'portrait',
          'landscape',
          'reversePortrait',
          'reverseLandscape',
        ],
      },
      'network': {
        'type': 'string',
        'enum': ['full', 'offline', 'lte', 'umts', 'edge', 'gprs'],
        'description':
            '"offline" turns Wi-Fi and mobile data off; "full" turns them '
            'back on and lifts any throttle.',
      },
    },
  },
};

const Map<String, Object?> deviceAppPermissionSchema = {
  'name': 'device_app_permission',
  'description':
      'Grant or revoke one permission for an installed app, so a test can '
      'start past — or straight into — the permission prompt. Android: a '
      'runtime permission, as CAMERA or android.permission.CAMERA; install-'
      'time permissions cannot be changed. iOS Simulator: a simctl privacy '
      'service — photos, location, contacts, microphone, calendar and the '
      'like; the camera and notifications are not available and are refused. '
      'REVOKING ENDS THE APP\'S PROCESS on both platforms.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      ..._deviceProperties,
      'appId': {'type': 'string'},
      'permission': {'type': 'string'},
      'action': {
        'type': 'string',
        'enum': ['grant', 'revoke'],
      },
    },
    'required': ['appId', 'permission', 'action'],
  },
};

const Map<String, Object?> deviceClearAppDataSchema = {
  'name': 'device_clear_app_data',
  'description':
      'Wipe an app back to first launch: its files, databases, preferences, '
      'caches and granted permissions, with the app stopped. THERE IS NO '
      'UNDO — a signed-in account, a draft, anything it stored is gone. '
      'Android only (pm clear). A simulator has no clear-data command and is '
      'refused: uninstall and reinstall the app there instead.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      ..._deviceProperties,
      'appId': {'type': 'string'},
    },
    'required': ['appId'],
  },
};
