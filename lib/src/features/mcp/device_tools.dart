import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../devices/application/device_providers.dart';
import '../devices/data/adb_service.dart';
import '../devices/domain/android_device.dart';
import '../devices/domain/device_input.dart';
import '../devices/domain/logcat_entry.dart';
import '../devices/domain/ui_node.dart';
import '../devices/domain/ui_summary.dart';

/// An attached Android device or emulator, as an agent can drive it.
///
/// Everything goes through the same `AdbService` the device pane uses, so the
/// agent and the person beside it are looking at and touching one device rather
/// than two views of it.
///
/// Lifted out of `LauncherControlServer` unchanged. It was the largest family
/// still inline there, and the seam was already drawn — the terminal, browser,
/// workspace and verification tools had each been given a file of their own,
/// and the device tools' only tie to the server was the container they read
/// providers from.
class DeviceControlTools {
  DeviceControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{
    'list_devices',
    'device_screenshot',
    'device_tap',
    'device_type',
    'device_key',
    'device_logcat',
    'device_ui_dump',
    'device_find_elements',
    'device_tap_element',
    'device_stop_emulator',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'list_devices' => _listDevices(),
        'device_screenshot' => _deviceScreenshot(args['serial'] as String?),
        'device_tap' => _deviceTap(
          args['serial'] as String?,
          (args['x'] as num?)?.round(),
          (args['y'] as num?)?.round(),
        ),
        'device_type' => _deviceType(
          args['serial'] as String?,
          args['text'] as String?,
        ),
        'device_key' => _deviceKey(
          args['serial'] as String?,
          args['key'] as String?,
        ),
        'device_logcat' => _deviceLogcat(
          serial: args['serial'] as String?,
          packageName: args['package'] as String?,
          level: args['level'] as String?,
          lines: (args['lines'] as num?)?.round(),
        ),
        'device_ui_dump' => _deviceUiDump(
          serial: args['serial'] as String?,
          full: args['full'] == true,
          filter: args['filter'] as String?,
          limit: (args['limit'] as num?)?.round(),
        ),
        'device_find_elements' => _deviceFindElements(
          serial: args['serial'] as String?,
          query: _uiQuery(args),
          limit: (args['limit'] as num?)?.round(),
        ),
        'device_tap_element' => _deviceTapElement(
          serial: args['serial'] as String?,
          query: _uiQuery(args),
          index: (args['index'] as num?)?.round(),
        ),
        'device_stop_emulator' => _deviceStopEmulator(
          args['serial'] as String?,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  AdbService _requireAdb() {
    final adb = _container.read(adbServiceProvider);
    if (adb == null) {
      throw StateError(
        'No Android SDK found. Set ANDROID_HOME or install the SDK to the '
        r'default location (%LOCALAPPDATA%\Android\Sdk).',
      );
    }
    return adb;
  }

  /// Resolves which device to act on. With exactly one ready device the serial
  /// can be omitted, which is what a caller will want almost every time.
  Future<AndroidDevice> _resolveDevice(String? serial) async {
    final devices = await _requireAdb().listDevices();
    if (devices.isEmpty) {
      throw StateError('No Android devices are connected.');
    }
    if (serial != null) {
      for (final device in devices) {
        if (device.serial == serial) {
          if (!device.isReady) {
            throw StateError(
              'Device $serial is ${device.state.name}, not ready. '
              'If it is unauthorized, accept the USB debugging prompt on the '
              'device.',
            );
          }
          return device;
        }
      }
      throw StateError('No device with serial $serial.');
    }
    final ready = devices.where((d) => d.isReady).toList();
    if (ready.isEmpty) {
      throw StateError(
        'No device is ready: '
        '${devices.map((d) => '${d.serial} (${d.state.name})').join(', ')}.',
      );
    }
    if (ready.length > 1) {
      throw StateError(
        'Several devices are connected; pass serial. Options: '
        '${ready.map((d) => d.serial).join(', ')}.',
      );
    }
    return ready.single;
  }

  Future<Object?> _listDevices() async {
    final adb = _requireAdb();
    final devices = await adb.listDevices();
    final avds = await adb.listAvds();
    return {
      'devices': [
        for (final device in devices)
          {
            'serial': device.serial,
            'name': device.displayName,
            'state': device.state.name,
            'ready': device.isReady,
            'emulator': device.isEmulator,
            'environmentId': device.environmentId,
            if (device.isReady)
              'screenSize': (await adb.screenSize(device.serial))?.toString(),
          },
      ],
      'avds': [
        for (final avd in avds) {'name': avd.name, 'running': avd.isRunning},
      ],
    };
  }

  Future<Object?> _deviceScreenshot(String? serial) async {
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final bytes = await adb.screenshot(device.serial);
    final size = await adb.screenSize(device.serial);
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'karmashala_${device.serial}_${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    // Returned as MCP content blocks so the model actually sees the image
    // instead of a wall of base64 in a JSON string.
    return {
      '_mcpContent': [
        {'type': 'image', 'data': base64Encode(bytes), 'mimeType': 'image/png'},
        {
          'type': 'text',
          'text':
              'Screenshot of ${device.displayName} (${device.serial})'
              '${size == null ? '' : ', screen $size device px'}. '
              'Saved to ${file.path}. Tap coordinates are in device pixels.',
        },
      ],
    };
  }

  Future<Object?> _deviceTap(String? serial, int? x, int? y) async {
    if (x == null || y == null) throw ArgumentError('x and y are required.');
    final device = await _resolveDevice(serial);
    await _requireAdb().tap(device.serial, x, y);
    return {'tapped': '($x, $y)', 'serial': device.serial};
  }

  Future<Object?> _deviceType(String? serial, String? text) async {
    if (text == null) throw ArgumentError('text is required.');
    final device = await _resolveDevice(serial);
    await _requireAdb().inputText(device.serial, text);
    return {'typed': text, 'serial': device.serial};
  }

  Future<Object?> _deviceKey(String? serial, String? key) async {
    if (key == null) throw ArgumentError('key is required.');
    final parsed = DeviceKey.parse(key);
    if (parsed == null) {
      throw ArgumentError(
        'Unknown key "$key". Valid keys: '
        '${DeviceKey.values.map((k) => k.name).join(', ')}.',
      );
    }
    final device = await _resolveDevice(serial);
    await _requireAdb().pressKey(device.serial, parsed);
    return {'pressed': parsed.name, 'serial': device.serial};
  }

  Future<Object?> _deviceLogcat({
    String? serial,
    String? packageName,
    String? level,
    int? lines,
  }) async {
    final device = await _resolveDevice(serial);
    final minLevel = _parseLogLevel(level) ?? LogLevel.verbose;
    final entries = await _requireAdb().readLogcat(
      device.serial,
      packageName: packageName,
      minLevel: minLevel,
      maxLines: lines ?? 200,
    );
    if (entries.isEmpty && packageName != null) {
      return {
        'serial': device.serial,
        'package': packageName,
        'lines': <String>[],
        'note': 'No output — $packageName does not appear to be running.',
      };
    }
    return {
      'serial': device.serial,
      'package': ?packageName,
      'lines': [for (final entry in entries) entry.toString()],
    };
  }

  // ---------------------------------------------------------------------------
  // The accessibility tree
  //
  // `device_tap` needs coordinates, and the only way an agent could previously
  // get them was to read them off a screenshot — which cannot say what is
  // tappable, and is one scale factor away from tapping the wrong thing while
  // reporting success. These three tools hand it the view hierarchy instead:
  // what is on screen, and exactly where to hit it.
  // ---------------------------------------------------------------------------

  UiElementQuery _uiQuery(Map<String, dynamic> args) => UiElementQuery(
    text: args['text'] as String?,
    resourceId: args['resourceId'] as String?,
    contentDescription: args['contentDesc'] as String?,
    className: args['className'] as String?,
    exact: args['exact'] == true,
    clickableOnly: args['clickable'] == true,
  );

  /// One line naming the device, the foreground app and the coordinate space.
  String _uiHeader(
    AndroidDevice device,
    UiHierarchy tree,
    DeviceScreenSize? screen,
  ) =>
      '${device.serial} · ${tree.packageName ?? 'unknown package'} · '
      'screen ${screen ?? 'unknown'} device px · rotation ${tree.rotation}';

  Future<Object?> _deviceUiDump({
    String? serial,
    bool full = false,
    String? filter,
    int? limit,
  }) async {
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final tree = await adb.dumpUiHierarchy(device.serial);
    final screen = await adb.screenSize(device.serial);

    if (full && filter == null) {
      final body = renderUiTree(tree, screen: screen);
      return _uiText([
        'Full UI hierarchy · ${_uiHeader(device, tree, screen)}',
        '${tree.nodeCount} nodes, indented by depth.',
        uiListingLegend,
        '',
        body,
      ]);
    }

    var nodes = full ? tree.allNodes.toList() : interestingNodes(tree);
    if (filter != null && filter.trim().isNotEmpty) {
      final needle = filter.trim().toLowerCase();
      bool has(String value) => value.toLowerCase().contains(needle);
      nodes = [
        for (final node in nodes)
          if (has(node.text) ||
              has(node.contentDescription) ||
              has(node.resourceId) ||
              has(node.className))
            node,
      ];
    }
    final rendered = renderUiElements(
      nodes,
      screen: screen,
      limit: limit ?? 200,
    );
    return _uiText([
      'UI hierarchy · ${_uiHeader(device, tree, screen)}',
      '${rendered.shown} of ${tree.nodeCount} nodes'
          '${full ? '' : ' (text-bearing or interactable)'}'
          '${filter == null ? '' : ', filtered by "$filter"'}'
          '${rendered.truncated == 0 ? '.' : ', ${rendered.truncated} more not '
                    'shown — raise limit.'}',
      uiListingLegend,
      '',
      rendered.listing.isEmpty ? '(nothing matched)' : rendered.listing,
      '',
      'Tap one with device_tap_element(text: "…"), which re-reads the screen '
          'and hits the element itself. The coordinates above also work with '
          'device_tap.',
    ]);
  }

  Future<Object?> _deviceFindElements({
    String? serial,
    required UiElementQuery query,
    int? limit,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className. '
        'Use device_ui_dump to see the whole screen.',
      );
    }
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final tree = await adb.dumpUiHierarchy(device.serial);
    final screen = await adb.screenSize(device.serial);
    final matches = tree.find(query);
    if (matches.isEmpty) {
      return _uiText([
        'No element matches $query on ${_uiHeader(device, tree, screen)}',
        '',
        'What is on screen instead:',
        uiListingLegend,
        renderUiElements(
          interestingNodes(tree),
          screen: screen,
          limit: 60,
        ).listing,
      ]);
    }
    final rendered = renderUiElements(
      matches,
      screen: screen,
      limit: limit ?? 50,
    );
    return _uiText([
      '${matches.length} element${matches.length == 1 ? '' : 's'} match '
          '$query · ${_uiHeader(device, tree, screen)}',
      'Best match first; an exact label beats a substring.',
      uiListingLegend,
      '',
      rendered.listing,
    ]);
  }

  /// Shuts a running emulator down.
  ///
  /// The serial is required rather than inferred: every other device tool
  /// defaults to "the only ready device", and silently defaulting a destructive
  /// action is a different thing entirely.
  Future<Object?> _deviceStopEmulator(String? serial) async {
    if (serial == null || serial.trim().isEmpty) {
      throw ArgumentError('serial is required for device_stop_emulator.');
    }
    final adb = _requireAdb();
    final devices = await adb.listDevices();
    final device = devices.where((d) => d.serial == serial).firstOrNull;
    if (device == null) {
      throw StateError('No device with serial $serial.');
    }
    if (!device.isEmulator) {
      throw StateError(
        '$serial is a physical device. Only emulators can be stopped.',
      );
    }
    final stopped = await adb.stopEmulator(serial);
    if (!stopped) {
      throw StateError(
        '$serial did not exit. It may be busy; try again, or close its window.',
      );
    }
    return {'serial': serial, 'stopped': true};
  }

  Future<Object?> _deviceTapElement({
    String? serial,
    required UiElementQuery query,
    int? index,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className.',
      );
    }
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final tree = await adb.dumpUiHierarchy(device.serial);
    final screen = await adb.screenSize(device.serial);
    final matches = tree.find(query);

    if (matches.isEmpty) {
      throw StateError(
        'Nothing matches $query on ${device.serial}. On screen now:\n'
        '${renderUiElements(interestingNodes(tree), screen: screen, limit: 60).listing}',
      );
    }

    final UiNode target;
    if (index != null) {
      if (index < 0 || index >= matches.length) {
        throw ArgumentError(
          'index $index is out of range: there are ${matches.length} matches.',
        );
      }
      target = matches[index];
    } else if (matches.length == 1) {
      target = matches.first;
    } else {
      // Several matches. One unambiguous exact label is still a decision we can
      // make; anything else is a guess, and a wrong tap is worse than an error
      // because the agent cannot tell it happened.
      final exact = [
        for (final node in matches)
          if (query.rank(node) == 0) node,
      ];
      if (exact.length == 1) {
        target = exact.single;
      } else {
        throw StateError(
          '$query matches ${matches.length} elements on ${device.serial}. '
          'Pass index to choose, or narrow the query:\n'
          '${_indexed(matches, screen)}',
        );
      }
    }

    final bounds = target.tapBounds;
    if (bounds == null) {
      throw StateError(
        'The matched element reports no bounds, so there is nowhere to tap: '
        '${describeUiNode(target, screen: screen)}',
      );
    }
    if (screen != null && !bounds.centerIsOnScreen(screen)) {
      throw StateError(
        'The matched element is off screen at ${bounds.raw} on a $screen '
        'display — it is scrolled out of view. Scroll it into view first; '
        'tapping its centre would hit whatever is really at that point.',
      );
    }

    final point = bounds.center;
    await adb.tap(device.serial, point.x, point.y);
    return _uiText([
      'Tapped (${point.x}, ${point.y}) on '
          '${describeUiNode(target, screen: screen)}',
      'Device ${device.serial}, ${tree.packageName ?? 'unknown package'}'
          '${matches.length == 1 ? '' : ', chosen from ${matches.length} matches'}.'
          '${target.enabled ? '' : ' NOTE: this element is disabled.'}',
      'Take a screenshot or dump again to confirm what changed.',
    ]);
  }

  /// The matches numbered, so the caller can pass `index`.
  String _indexed(List<UiNode> matches, DeviceScreenSize? screen) => [
    for (var i = 0; i < matches.length && i < 20; i++)
      '[$i] ${describeUiNode(matches[i], screen: screen)}',
  ].join('\n');

  /// Wraps a listing as an MCP text block.
  ///
  /// Deliberately not returned as a JSON map: the bridge pretty-prints every
  /// map result, and one JSON object per node costs several times what one line
  /// per node does. The whole point of this surface is that a screen fits in a
  /// few hundred tokens.
  Object _uiText(List<String> sections) => {
    '_mcpContent': [
      {'type': 'text', 'text': sections.join('\n')},
    ],
  };

  LogLevel? _parseLogLevel(String? level) {
    if (level == null) return null;
    final needle = level.trim().toLowerCase();
    for (final value in LogLevel.values) {
      if (value.name == needle || value.code.toLowerCase() == needle) {
        return value;
      }
    }
    return null;
  }
}

/// The schemas for [DeviceControlTools].
const List<Map<String, dynamic>> deviceControlToolSchemas = [
    {
      'name': 'list_devices',
      'description':
          'List connected Android devices and running emulators, with their '
          'serial, model, and whether they are ready. Devices that are not '
          'usable (unauthorized, offline) are included and marked so you can '
          'explain the problem rather than reporting no devices.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    },
    {
      'name': 'device_screenshot',
      'description':
          'Capture the current screen of an Android device as a PNG image. '
          'Use this to see what an app is actually showing. serial is optional '
          'when exactly one device is connected.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {
            'type': 'string',
            'description': 'Device serial from list_devices.',
          },
        },
      },
    },
    {
      'name': 'device_tap',
      'description':
          'Tap the device screen at (x, y) in DEVICE pixel coordinates (the '
          'coordinate space reported by list_devices as screen size, not the '
          'size of any screenshot you scaled). Take a screenshot first to '
          'decide where to tap.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'x': {'type': 'number', 'description': 'X in device pixels.'},
          'y': {'type': 'number', 'description': 'Y in device pixels.'},
        },
        'required': ['x', 'y'],
      },
    },
    {
      'name': 'device_type',
      'description':
          'Type text into whatever field currently has focus on the device. '
          'Tap the field first. Spaces and shell characters are escaped for you.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    },
    {
      'name': 'device_key',
      'description':
          'Press a hardware button: back, home, recents, power, volumeUp, '
          'volumeDown, enter, tab or delete.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'key': {
            'type': 'string',
            'description':
                'back | home | recents | power | volumeUp | '
                'volumeDown | enter | tab | delete',
          },
        },
        'required': ['key'],
      },
    },
    {
      'name': 'device_logcat',
      'description':
          'Read recent logcat output, newest last. Filter to one app with '
          'package (strongly recommended — the unfiltered system log is huge '
          'and mostly noise), and raise level to see only warnings or errors. '
          'Returns nothing if the package is not running.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'package': {
            'type': 'string',
            'description': 'Application id, e.g. com.example.app.',
          },
          'level': {
            'type': 'string',
            'description':
                'Minimum level: verbose, debug, info, warning, error, fatal.',
          },
          'lines': {
            'type': 'number',
            'description': 'Max lines (default 200).',
          },
        },
      },
    },
    {
      'name': 'device_stop_emulator',
      'description':
          'Shut a running Android emulator down, freeing its memory and CPU. '
          'Emulators only — a physical device cannot be stopped this way. '
          'Anything the emulator has not written to a snapshot is lost.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {
            'type': 'string',
            'description': 'Emulator serial, e.g. emulator-5554.',
          },
        },
        'required': ['serial'],
      },
    },
    {
      'name': 'device_ui_dump',
      'description':
          'Read the accessibility (view) hierarchy of the current screen: what '
          'is on it, what each element says, and the exact point to tap for '
          'each one. Prefer this over device_screenshot when you intend to '
          'touch something — a screenshot cannot tell you what is tappable, '
          'and coordinates read off an image are guesswork. By default only '
          'nodes that carry text or accept input are listed; pass full=true '
          'for every node, including layout containers.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'full': {
            'type': 'boolean',
            'description':
                'Include every node instead of only the useful ones. Much '
                'larger; use it only when the default listing is missing '
                'something.',
          },
          'filter': {
            'type': 'string',
            'description':
                'Keep only nodes whose text, content-description, resource id '
                'or class contains this (case-insensitive).',
          },
          'limit': {
            'type': 'number',
            'description': 'Max nodes to list (default 200).',
          },
        },
      },
    },
    {
      'name': 'device_find_elements',
      'description':
          'Find elements on the current screen by text, resource id, '
          'content-description or class, and get the point to tap for each. '
          'Matching is case-insensitive and by substring unless exact=true. '
          'text matches BOTH the text and the content-description, which is '
          'what makes it work on Flutter apps: they put their labels in '
          'content-desc and leave text empty.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'text': {
            'type': 'string',
            'description': 'Visible text or content-description to look for.',
          },
          'resourceId': {
            'type': 'string',
            'description':
                'Resource id, in full (com.app:id/ok) or short (ok).',
          },
          'contentDesc': {
            'type': 'string',
            'description': 'Content-description only, ignoring text.',
          },
          'className': {
            'type': 'string',
            'description': 'Class, in full or by last segment (Button).',
          },
          'exact': {
            'type': 'boolean',
            'description': 'Require the whole value to match, not a substring.',
          },
          'clickable': {
            'type': 'boolean',
            'description': 'Keep only elements marked clickable.',
          },
          'limit': {
            'type': 'number',
            'description': 'Max matches (default 50).',
          },
        },
      },
    },
    {
      'name': 'device_tap_element',
      'description':
          'Tap the element matching a query rather than a coordinate — '
          'tap_element(text: "Sign in") instead of tap(357, 126). This is far '
          'more reliable: it survives layout changes, it cannot be off by a '
          'scale factor, and it tells you what it actually hit. It re-reads '
          'the hierarchy first, so it acts on the screen as it is now. '
          'Refuses rather than guessing when the query matches several '
          'elements (pass index) or nothing, and refuses to tap an element '
          'that is scrolled off screen.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'text': {
            'type': 'string',
            'description': 'Visible text or content-description to tap.',
          },
          'resourceId': {'type': 'string'},
          'contentDesc': {'type': 'string'},
          'className': {'type': 'string'},
          'exact': {'type': 'boolean'},
          'clickable': {
            'type': 'boolean',
            'description': 'Only consider elements marked clickable.',
          },
          'index': {
            'type': 'number',
            'description':
                'Which match to tap (0-based) when the query is ambiguous.',
          },
        },
      },
    },
];
