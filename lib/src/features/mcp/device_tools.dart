import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../devices/application/device_claims.dart';
import '../devices/domain/device_driver.dart';
import '../devices/domain/device_input.dart';
import '../devices/domain/ui_node.dart';
import '../devices/domain/ui_summary.dart';
import 'device_app_tools.dart';
import 'device_drive_tools.dart';
import 'device_file_tools.dart';
import 'device_inventory_tools.dart';
import 'device_tool_support.dart';

// The locating policy is quoted by tests and by the two schemas here that
// splice it, and this file is the door callers come to. Nothing else is
// re-exported: a family is imported by name.
export 'device_drive_tools.dart' show kDeviceLocatingPolicy;

/// An attached Android device, an Android emulator, or an iOS Simulator, as an
/// agent can drive it end to end: list, boot, install, launch, tap, read back.
///
/// Everything goes through the same services the device pane uses, so the agent
/// and the person beside it are looking at and touching one device rather than
/// two views of it.
///
/// ## One vocabulary, not two
///
/// These tools were Android-only, and every one of them took a `serial`. Adding
/// simulators could have meant a `simulator_*` family beside them — but
/// `device_tap` and `simulator_tap` are the same verb applied to the same kind
/// of object, and splitting them makes "which family do I call" a question the
/// agent has to answer *before* it knows what it is holding. The identifiers
/// give nothing away: `emulator-5554` and `70592006-11CD-…` are both just
/// strings that came out of `list_devices`.
///
/// So there is one family, the id is the discriminator, and `DeviceFleet` does
/// the dispatch. Every existing Android caller keeps working unchanged, because
/// an Android serial still resolves to exactly what it always did.
///
/// ## Nothing in this file knows what kind of device it is holding
///
/// Every handler below resolves a [DeviceDriver] and then speaks only that
/// interface. There is no `if (isSimulator)` here, and adding one would be the
/// bug: the engine behind a simulator has already been swapped once — idb out,
/// WebDriverAgent in — and a `CoreSimulator` or `pymobiledevice3` driver should
/// cost this file nothing. The only place that names a platform is
/// `list_devices`, which is a *listing* and whose whole job is to say which is
/// which.
///
/// ## A tool never pretends
///
/// Two mechanisms, both of them checked here before anything is attempted:
/// [DeviceCapability], for what a driver cannot do at all, and [DeviceRefusal],
/// for what it cannot do with these particular arguments. Either way the caller
/// gets a sentence naming the device, the thing that is missing, and what still
/// works. An agent has no eyes, so a verb that quietly does nothing reads to it
/// as a verb that worked.
///
/// Lifted out of `LauncherControlServer` unchanged. It was the largest family
/// still inline there, and the seam was already drawn — the terminal, browser,
/// workspace and verification tools had each been given a file of their own,
/// and the device tools' only tie to the server was the container they read
/// providers from.
///
/// ## One task per device
///
/// Everything below that changes a device goes through [DeviceClaims] first, so
/// two agents cannot interleave taps on one phone. Everything that only *reads*
/// one goes through it too, but only to say the holder is still working — a read
/// never takes a claim and is never refused. See `device_claim.dart` for why a
/// device gets a lock when a repository deliberately does not.
class DeviceControlTools extends DeviceToolFamily {
  DeviceControlTools(super.container, {super.callerSessionId});

  static const Set<String> _names = <String>{
    'device_screenshot',
    'device_logcat',
    'device_ui_dump',
    'device_find_elements',
  };

  /// The families that have moved out, each answering its own names.
  late final _app = DeviceAppTools(container, callerSessionId: callerSessionId);
  late final _drive = DeviceDriveTools(
    container,
    callerSessionId: callerSessionId,
  );
  late final _inventory = DeviceInventoryTools(
    container,
    callerSessionId: callerSessionId,
  );
  late final _file = DeviceFileTools(
    container,
    callerSessionId: callerSessionId,
  );

  static bool handles(String name) =>
      _names.contains(name) ||
      DeviceAppTools.handles(name) ||
      DeviceDriveTools.handles(name) ||
      DeviceInventoryTools.handles(name) ||
      DeviceFileTools.handles(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        _ when DeviceAppTools.handles(name) => _app.call(name, args),
        _ when DeviceDriveTools.handles(name) => _drive.call(name, args),
        _ when DeviceInventoryTools.handles(name) =>
          _inventory.call(name, args),
        _ when DeviceFileTools.handles(name) => _file.call(name, args),
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

  // ---------------------------------------------------------------------------
  // Looking at a screen
  // ---------------------------------------------------------------------------

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

    // The warning is the whole reason DeviceScreenshot carries two spaces. On a
    // simulator the capture is the pixel backing store and the tap is in
    // points; a coordinate measured off this image and handed to device_tap
    // lands off the bottom of the screen while the call reports success.
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

  // ---------------------------------------------------------------------------
  // Logs
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // The accessibility tree
  //
  // `device_tap` needs coordinates, and the only way an agent could previously
  // get them was to read them off a screenshot — which cannot say what is
  // tappable, and is one scale factor away from tapping the wrong thing while
  // reporting success. These three tools hand it the view hierarchy instead:
  // what is on screen, and exactly where to hit it.
  //
  // On a simulator this is the *only* honest way to get a coordinate, because
  // the screenshot is in pixels and the tap is in points.
  // ---------------------------------------------------------------------------

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
      // Said here rather than only in the tool description, because the moment
      // it is needed is the moment a dump has come back looking complete and
      // empty.
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
/// The schemas for [DeviceControlTools].
const List<Map<String, dynamic>> deviceControlToolSchemas = [
  listDevicesSchema,
  {
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
  },
  deviceTapSchema,
  deviceTypeSchema,
  deviceKeySchema,
  deviceFilesListSchema,
  deviceFilePullSchema,
  deviceFilePushSchema,
  {
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
  },
  deviceBootSchema,
  deviceInstallAppSchema,
  deviceLaunchAppSchema,
  deviceTerminateAppSchema,
  deviceStopEmulatorSchema,
  {
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
  },
  {
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
  },
  deviceTapElementSchema,
];
