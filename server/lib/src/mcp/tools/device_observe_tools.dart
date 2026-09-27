import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:karmashala_devices/karmashala_devices.dart';
import 'device_drive_tools.dart';
import 'device_tool_support.dart';

/// Looking at a device without touching it. A coordinate off a screenshot is in
/// pixels where the tap is in points, so the hierarchy is the honest source.
class DeviceObserveTools extends DeviceToolFamily {
  DeviceObserveTools(super.devices, {super.callerSessionId});

  static const Set<String> _names = <String>{
    'device_screenshot',
    'device_logcat',
    'device_ui_dump',
    'device_find_elements',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'device_screenshot' => _deviceScreenshot(deviceIdIn(args)),
        'device_logcat' => _deviceLogcat(
          id: deviceIdIn(args),
          packageName: args['package'] as String?,
          level: args['level'] as String?,
          lines: (args['lines'] as num?)?.round(),
        ),
        'device_ui_dump' => _deviceUiDump(
          id: deviceIdIn(args),
          full: args['full'] == true,
          filter: args['filter'] as String?,
          limit: (args['limit'] as num?)?.round(),
        ),
        'device_find_elements' => _deviceFindElements(
          id: deviceIdIn(args),
          query: uiQueryIn(args),
          limit: (args['limit'] as num?)?.round(),
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Future<Object?> _deviceScreenshot(String? id) async {
    final driver = await driverThatCan(
      id,
      'device_screenshot',
      DeviceCapability.screenshot,
    );
    final shot = await driver.screenshot();
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'karmashala_${driver.target.fileSafeId}_'
        '${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(shot.bytes, flush: true);

    // On a simulator the capture is the pixel backing store and the tap is in
    // points, so a coordinate off this image lands off the bottom of the screen.
    final spaces = shot.spacesAgree
        ? 'Tap coordinates are in ${shot.tapSpace.label}, the same space as '
              'this image.'
        : 'WARNING: this image is in ${shot.imageSpace.label}, but device_tap '
              'on this device takes ${shot.tapSpace.label} — on a 3x display '
              'they differ by a factor of three. Use device_ui_dump or '
              'device_tap_element, whose coordinates are already in '
              '${shot.tapSpace.label}, rather than measuring off this picture.';

    // Returned as MCP content blocks so the model actually sees the image
    // instead of a wall of base64 in a JSON string.
    return {
      '_mcpContent': [
        {
          'type': 'image',
          'data': base64Encode(shot.bytes),
          'mimeType': 'image/png',
        },
        {
          'type': 'text',
          'text':
              'Screenshot of ${driver.target.label} (${driver.target.id})'
              '${shot.size == null ? '' : ', ${shot.size} '
                        '${shot.imageSpace.label}'}. '
              'Saved to ${file.path}. $spaces',
        },
      ],
    };
  }

  Future<Object?> _deviceLogcat({
    String? id,
    String? packageName,
    String? level,
    int? lines,
  }) async {
    final driver = await driverThatCan(
      id,
      'device_logcat',
      DeviceCapability.logs,
    );
    final read = await driver.readLog(
      filter: packageName,
      level: level,
      lines: lines ?? 200,
    );
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'package': ?packageName,
      'lines': read.lines,
      'note': ?read.note,
    };
  }

  Future<Object?> _deviceUiDump({
    String? id,
    bool full = false,
    String? filter,
    int? limit,
  }) async {
    final driver = await driverThatCan(
      id,
      'device_ui_dump',
      DeviceCapability.uiTree,
    );
    final read = await driver.describeScreen();
    recordLook(driver, read);
    final tree = read.tree;
    final screen = read.screen;

    if (full && filter == null) {
      final body = renderUiTree(tree, screen: screen);
      return uiTextBlock([
        'Full UI hierarchy · ${uiHeader(driver, read)}',
        '${tree.nodeCount} nodes, indented by depth.',
        uiListingLegend,
        spaceLine(read),
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
    return uiTextBlock([
      'UI hierarchy · ${uiHeader(driver, read)}',
      '${rendered.shown} of ${tree.nodeCount} nodes'
          '${full ? '' : ' (text-bearing or interactable)'}'
          '${filter == null ? '' : ', filtered by "$filter"'}'
          '${rendered.truncated == 0 ? '.' : ', ${rendered.truncated} more not '
                    'shown — raise limit.'}',
      uiListingLegend,
      spaceLine(read),
      '',
      rendered.listing.isEmpty ? '(nothing matched)' : rendered.listing,
      '',
      // Said here rather than only in the tool description, because it is needed
      // exactly when a dump has come back looking complete and empty.
      ...?_canvasHint(tree, screen),
      'Tap one with device_tap_element(text: "…"), which re-reads the screen '
          'and hits the element itself. The coordinates above also work with '
          'device_tap.',
    ]);
  }

  /// One line warning that the screen is painted, not composed of widgets.
  List<String>? _canvasHint(UiHierarchy tree, DeviceScreenSize? screen) {
    final node = canvasLikeNode(tree, screen);
    if (node == null) return null;
    return [
      'NOTE: ${describeUiNode(node, screen: screen)} is a large view with no '
          'text of its own — a custom-painted surface (Flutter CustomPaint, a '
          'canvas game, a terminal) exposes nothing to this dump. Read its '
          'content with device_screenshot instead of dumping again.',
      '',
    ];
  }

  Future<Object?> _deviceFindElements({
    String? id,
    required UiElementQuery query,
    int? limit,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className. '
        'Use device_ui_dump to see the whole screen.',
      );
    }
    final driver = await driverThatCan(
      id,
      'device_find_elements',
      DeviceCapability.uiTree,
    );
    final read = await driver.describeScreen();
    recordLook(driver, read);
    final tree = read.tree;
    final screen = read.screen;
    final matches = tree.find(query);
    if (matches.isEmpty) {
      return uiTextBlock([
        'No element matches $query on ${uiHeader(driver, read)}',
        '',
        'What is on screen instead:',
        uiListingLegend,
        spaceLine(read),
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
    return uiTextBlock([
      '${matches.length} element${matches.length == 1 ? '' : 's'} match '
          '$query · ${uiHeader(driver, read)}',
      'Best match first; an exact label beats a substring.',
      uiListingLegend,
      spaceLine(read),
      '',
      rendered.listing,
    ]);
  }
}

/// The schemas for [DeviceObserveTools].
const Map<String, Object?> deviceScreenshotSchema = {
  'name': 'device_screenshot',
  'description':
      'Capture the current screen of an Android device or iOS simulator as a '
      'PNG image. Use this to see what an app is actually showing. serial '
      '(or udid) is optional when exactly one device is ready. NOTE on a '
      'simulator the image is in PIXELS while taps are in POINTS — prefer '
      'device_ui_dump when you intend to touch something.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {
        'type': 'string',
        'description': 'Android serial or simulator udid from list_devices.',
      },
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
    },
  },
};

const Map<String, Object?> deviceLogcatSchema = {
  'name': 'device_logcat',
  'description':
      'Read recent device log output, newest last. On Android this is '
      'logcat: filter to one app with package (strongly recommended — the '
      'unfiltered system log is huge and mostly noise) and raise level to '
      'see only warnings or errors. On an iOS simulator it is `log show` '
      'over the last 5 minutes: level is refused (iOS levels are not Android '
      'levels) and package is matched as a plain substring of each line, '
      'which the reply says.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'package': {
        'type': 'string',
        'description':
            'Android application id, e.g. com.example.app. On iOS, a '
            'substring to match in each line.',
      },
      'level': {
        'type': 'string',
        'description':
            'Android only. Minimum level: verbose, debug, info, warning, '
            'error, fatal.',
      },
      'lines': {'type': 'number', 'description': 'Max lines (default 200).'},
    },
  },
};

const Map<String, Object?> deviceUiDumpSchema = {
  'name': 'device_ui_dump',
  'description':
      'Read the accessibility (view) hierarchy of the current screen: what '
      'is on it, what each element says, and the exact point to tap for each '
      'one. Works on Android (uiautomator) and on an iOS simulator '
      '(WebDriverAgent). Prefer this over device_screenshot when you intend '
      'to touch something — a screenshot cannot tell you what is tappable, '
      'coordinates read off an image are guesswork, and on iOS the image is '
      'in a different unit from the tap. By default only nodes that carry '
      'text or accept input are listed; pass full=true for every node, '
      'including layout containers. Custom-painted views — Flutter '
      'CustomPaint, canvas games, embedded terminals — expose no text here '
      'at all and appear as one empty View; read those with '
      'device_screenshot rather than dumping again. $kDeviceLocatingPolicy',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
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
            'Keep only nodes whose text, content-description, resource id or '
            'class contains this (case-insensitive).',
      },
      'limit': {
        'type': 'number',
        'description': 'Max nodes to list (default 200).',
      },
    },
  },
};

const Map<String, Object?> deviceFindElementsSchema = {
  'name': 'device_find_elements',
  'description':
      'Find elements on the current screen by text, resource id, '
      'content-description or class, and get the point to tap for each. '
      'Matching is case-insensitive and by substring unless exact=true. text '
      'matches BOTH the text and the content-description, which is what '
      'makes it work on Flutter apps: they put their labels in content-desc '
      'and leave text empty. On iOS the same query runs against the XCUITest '
      'tree, where an element\'s value and label are mapped onto those same '
      'two fields. $kDeviceLocatingPolicy',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'text': {
        'type': 'string',
        'description': 'Visible text or content-description to look for.',
      },
      'resourceId': {
        'type': 'string',
        'description': 'Resource id, in full (com.app:id/ok) or short (ok).',
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
      'limit': {'type': 'number', 'description': 'Max matches (default 50).'},
    },
  },
};
