import 'package:karmashala_devices/devices.dart';
import 'device_tool_support.dart';

/// Touching a device: a tap by name, a tap by coordinate, text and keys.
///
/// The four verbs that change what is on screen, and the only place in this
/// family that refuses on what it read a moment ago. [kDeviceLocatingPolicy]
/// below says which of the two taps to reach for; `_vetCoordinate` is what
/// makes that sentence true, because it costs the fallback exactly what the
/// preferred path costs.
class DeviceDriveTools extends DeviceToolFamily {
  DeviceDriveTools(super.container, {super.callerSessionId});

  static const Set<String> _names = <String>{
    'device_tap',
    'device_type',
    'device_key',
    'device_tap_element',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'device_tap' => _deviceTap(
          deviceIdIn(args),
          (args['x'] as num?)?.round(),
          (args['y'] as num?)?.round(),
          // Default on. The check is skipped only when the caller says so, so a
          // screen with nothing in its hierarchy is a decision rather than a
          // silent gap.
          verify: args['verify'] != false,
        ),
        'device_type' => _deviceType(
          deviceIdIn(args),
          args['text'] as String?,
          submit: args['submit'] == true,
        ),
        'device_key' => _deviceKey(deviceIdIn(args), args['key'] as String?),
        'device_tap_element' => _deviceTapElement(
          id: deviceIdIn(args),
          query: uiQueryIn(args),
          index: (args['index'] as num?)?.round(),
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// Taps a raw coordinate, having first looked at what is under it.
  ///
  /// ## The safety net, and why it is on the fallback tool
  ///
  /// This is the one tool that acts on numbers a caller worked out earlier, so
  /// it is the one tool that can tap where an element *was*. The check is a
  /// single [DeviceDriver.describeScreen] immediately before the touch — the
  /// very same read [_deviceTapElement] already pays — which is the argument
  /// that matters: **vetting the fallback costs exactly what the preferred path
  /// costs**, so there is no longer a speed reason to prefer coordinates.
  ///
  /// It refuses on *positive* evidence and never on the absence of it. A screen
  /// whose structure has moved since this app last read it is evidence; having
  /// never read the screen is not, and produces a note rather than a refusal —
  /// the coordinates may have come from a screenshot, or from the person
  /// sitting there. Same rule as everywhere else in this codebase: an unknown
  /// is not a zero.
  ///
  /// It also never turns a working call into a refusal for a reason of its own.
  /// A driver with no [DeviceCapability.uiTree] cannot be checked and is tapped
  /// anyway, and a screen read that *fails* — uiautomator does fall over
  /// mid-animation and on secure windows — is reported, not raised. The one
  /// thing that was silently wrong before and is now refused is a coordinate
  /// off the display, which used to be sent and reported as a success.
  ///
  /// `verify: false` is the documented way out, and the same one Artemis takes
  /// for its fast-action bursts: a custom-painted surface exposes nothing to
  /// the hierarchy, so there is nothing there for a check to be about.
  Future<Object?> _deviceTap(
    String? id,
    int? x,
    int? y, {
    bool verify = true,
  }) async {
    if (x == null || y == null) throw ArgumentError('x and y are required.');
    final driver = await driverToDrive(
      id,
      'device_tap',
      DeviceCapability.input,
    );
    // After the claim, on purpose: a refusal below tells the caller to look
    // again, and it should still be holding the device when it does.
    final checked = verify
        ? await _vetCoordinate(driver, x, y)
        : const _CoordinateCheck(
            verdict:
                'not checked — verify: false. Nothing was read before the tap, '
                'so this reply says only that the event was sent.',
          );
    await driver.tap(x, y);
    return {
      'tapped': '($x, $y)',
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'coordinateSpace': driver.coordinateSpace.label,
      'checked': checked.verdict,
      'under': ?checked.under,
      'prefer': ?checked.prefer,
    };
  }

  /// Reads the screen and says what ([x], [y]) is about to hit, or refuses.
  Future<_CoordinateCheck> _vetCoordinate(
    DeviceDriver driver,
    int x,
    int y,
  ) async {
    if (!driver.can(DeviceCapability.uiTree)) {
      return _CoordinateCheck(
        verdict:
            'not checked — ${driver.missingReason(DeviceCapability.uiTree)!} '
            'The tap was sent unverified.',
      );
    }
    final ScreenRead read;
    try {
      read = await driver.describeScreen();
    } on Object catch (error) {
      // Broad on purpose. Every way a screen read can fail — uiautomator
      // mid-animation, a secure window, a device that went away between the
      // claim and the read — ends the same way here: the check could not be
      // performed, which is not the same as the tap being wrong. Turning an
      // unavailable check into a refusal would break a tool that works today.
      return _CoordinateCheck(
        verdict:
            'not checked — reading the screen failed ($error). The tap was '
            'sent unverified.',
      );
    }

    final screen = read.screen;
    if (screen != null && (x < 0 || y < 0 || x >= screen.width || y >= screen.height)) {
      throw DeviceRefusal(
        'device_tap: ($x, $y) is off a $screen ${read.space.label} screen on '
        '${driver.target.id}. A tap outside the display does nothing and '
        'reports success, which is why this is refused rather than sent. '
        'device_ui_dump reports coordinates already in the right space for '
        'this device.',
      );
    }

    // Read before the new one is filed, or the comparison is with itself.
    final earlier = screens.lastLookAt(driver.target.id);
    final seen = screens.observationOf(
      deviceId: driver.target.id,
      tree: read.tree,
      app: read.app,
      bySessionId: callerSessionId,
    );

    String? staleness;
    if (earlier != null && !seen.matches(earlier)) {
      final age = seen.at.difference(earlier.at);
      if (age <= kDeviceLookWindow) {
        // Deliberately *not* filed. A refusal that recorded the new screen
        // would let the identical retry through against a screen the caller
        // never looked at, which is the same blind tap one round trip later.
        throw DeviceRefusal(
          'device_tap: the screen has moved since this app last read it, so '
          '($x, $y) is a coordinate for a screen that is gone. '
          '${driver.target.id} was read '
          '${describeDriveAge(age)} and ${seen.differenceFrom(earlier)}. A '
          'coordinate computed against the old screen lands wherever the new '
          'one happens to put something, and the reply would say it worked.\n'
          'Read it again and act on what is there: device_find_elements then '
          'device_tap_element, which re-reads the screen, hits the element '
          'itself, costs exactly what this call costs and survives the next '
          'change too. To tap blind anyway — a canvas, a game, a '
          'custom-painted surface with nothing in the hierarchy — pass '
          'verify: false.',
        );
      }
      staleness =
          'the screen has changed since it was last read '
          '${describeDriveAge(age)}, but that reading is older than '
          '${kDeviceLookWindow.inMinutes}m and so is not evidence about where '
          'these coordinates came from — not refused for that reason';
    } else if (earlier == null) {
      staleness =
          'nothing this app has read says where ($x, $y) came from — no '
          'device_ui_dump or device_find_elements has been run on '
          '${driver.target.id}, so it was checked against the screen as it is '
          'now and nothing else';
    }

    screens.file(seen);

    final node = read.tree.at(x, y);
    return _CoordinateCheck(
      verdict: staleness == null
          ? 'against a read taken just now, which matches the screen last read '
                '${describeDriveAge(seen.at.difference(earlier!.at))}'
          : 'against a read taken just now — $staleness',
      under: node == null
          ? 'nothing in the hierarchy covers ($x, $y); on a custom-painted '
                'surface that is normal, elsewhere it means the tap lands on '
                'no element'
          : describeUiNode(node, screen: screen),
      prefer: node == null ? null : _preferElementOver(node),
    );
  }

  /// One line when this screen is not the one this app last read, or null.
  ///
  /// A note and never a refusal, and that asymmetry is the locating policy
  /// stated as behaviour: a dynamic locator is resolved against the screen in
  /// front of it, so a change is something it *survives* — while the same
  /// change makes a raw coordinate wrong, which is why `device_tap` refuses on
  /// it. Said anyway, because the caller's wider plan was built on the older
  /// screen and this tap succeeding is not evidence the rest of it will.
  List<String>? _screenMovedSince(DeviceDriver driver, ScreenRead read) {
    final earlier = screens.lastLookAt(driver.target.id);
    if (earlier == null) return null;
    final seen = screens.observationOf(
      deviceId: driver.target.id,
      tree: read.tree,
      app: read.app,
      bySessionId: callerSessionId,
    );
    if (seen.matches(earlier)) return null;
    return [
      'NOTE: the screen changed since it was last read '
          '${describeDriveAge(seen.at.difference(earlier.at))} — '
          '${seen.differenceFrom(earlier)}. This tap resolved against the '
          'screen as it is now, so it is right; any coordinate you are still '
          'holding from that read is not.',
    ];
  }

  /// The `device_tap_element` call that would have found [node], said where the
  /// caller is already reading — the locating policy at the moment it applies.
  String? _preferElementOver(UiNode node) {
    final ({String field, String value})? locator = switch (node) {
      _ when node.text.isNotEmpty => (field: 'text', value: node.text),
      _ when node.contentDescription.isNotEmpty => (
        field: 'text',
        value: node.contentDescription,
      ),
      _ when node.resourceId.isNotEmpty => (
        field: 'resourceId',
        value: node.resourceId,
      ),
      _ => null,
    };
    if (locator == null) return null;
    return 'device_tap_element(${locator.field}: "${locator.value}") hits that '
        'element by name: it survives a layout change, cannot be off by a '
        'scale factor, and costs exactly what this call costs.';
  }

  Future<Object?> _deviceType(
    String? id,
    String? text, {
    bool submit = false,
  }) async {
    if (text == null) throw ArgumentError('text is required.');
    final driver = await driverToDrive(
      id,
      'device_type',
      DeviceCapability.input,
    );
    await driver.type(text);
    if (!submit) {
      return {
        'typed': text,
        'serial': driver.target.id,
        'platform': driver.target.platform.name,
      };
    }
    // A real Enter key rather than the IME's action. A view that handles its
    // own key events — a Flutter `TextInputClient`, an embedded terminal —
    // receives committed text but never the action, so an IME-only submit is a
    // silent no-op there and the reply still says "typed". Pressing the key is
    // what the caller would have done next anyway.
    if (!driver.can(DeviceCapability.keys)) {
      throw DeviceRefusal(
        'device_type(submit: true): ${driver.missingReason(DeviceCapability.keys)!} '
        'The text was typed; send the newline yourself.',
      );
    }
    final press = await driver.pressKey(DeviceKey.enter);
    return {
      'typed': text,
      'submitted': true,
      'submittedAs': press.how,
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
    };
  }

  Future<Object?> _deviceKey(String? id, String? key) async {
    if (key == null) throw ArgumentError('key is required.');
    final parsed = DeviceKey.parse(key);
    if (parsed == null) {
      throw ArgumentError(
        'Unknown key "$key". Valid keys: '
        '${DeviceKey.values.map((k) => k.name).join(', ')}.',
      );
    }
    final driver = await driverToDrive(
      id,
      'device_key',
      DeviceCapability.keys,
    );
    // The driver refuses the individual keys its device does not have. That is
    // per-key rather than a capability because a device with *some* of them is
    // the normal case — see SimulatorDeviceDriver.pressKey.
    final press = await driver.pressKey(parsed);
    return {
      'pressed': press.key.name,
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'as': press.how,
    };
  }

  Future<Object?> _deviceTapElement({
    String? id,
    required UiElementQuery query,
    int? index,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className.',
      );
    }
    // Both capabilities, checked before the read: a driver that could describe
    // a screen but not touch it would otherwise dump the tree, pick a target
    // and fail at the last step, having spent the round trip.
    final driver = await driverToDrive(
      id,
      'device_tap_element',
      DeviceCapability.uiTree,
    );
    require(driver, 'device_tap_element', DeviceCapability.input);
    // The read *is* this tool's safety net: it resolves the locator against the
    // screen as it is now, so a dialog that arrived between look and tap is
    // caught here rather than by the user. What the note below adds is the
    // other half — that the plan the caller built is stale even though this
    // call succeeded.
    final read = await driver.describeScreen();
    final moved = _screenMovedSince(driver, read);
    recordLook(driver, read);
    final tree = read.tree;
    final screen = read.screen;
    final matches = tree.find(query);

    if (matches.isEmpty) {
      throw DeviceRefusal(
        'Nothing matches $query on ${driver.target.id}. On screen now:\n'
        '${renderUiElements(interestingNodes(tree), screen: screen, limit: 60).listing}',
      );
    }

    final UiNode element;
    if (index != null) {
      if (index < 0 || index >= matches.length) {
        throw ArgumentError(
          'index $index is out of range: there are ${matches.length} matches.',
        );
      }
      element = matches[index];
    } else if (matches.length == 1) {
      element = matches.first;
    } else {
      // Several matches. One unambiguous exact label is still a decision we can
      // make; anything else is a guess, and a wrong tap is worse than an error
      // because the agent cannot tell it happened.
      final exact = [
        for (final node in matches)
          if (query.rank(node) == 0) node,
      ];
      if (exact.length == 1) {
        element = exact.single;
      } else {
        throw DeviceRefusal(
          '$query matches ${matches.length} elements on ${driver.target.id}. '
          'Pass index to choose, or narrow the query:\n'
          '${indexedMatches(matches, screen)}',
        );
      }
    }

    final bounds = element.tapBounds;
    if (bounds == null) {
      throw DeviceRefusal(
        'The matched element reports no bounds, so there is nowhere to tap: '
        '${describeUiNode(element, screen: screen)}',
      );
    }
    // A node covering nearly the whole screen is a scrim or a modal barrier,
    // never the thing anybody meant. Android exposes one as a clickable node
    // called "Dismiss" spanning the display, directly behind the dialog whose
    // button the caller asked for — so tapping it closes the dialog and throws
    // away the state under test, and the reply would read like a success.
    // Refused rather than ranked down: there is no query for which the right
    // answer is the barrier.
    if (screen != null && bounds.coversMostOf(screen)) {
      throw DeviceRefusal(
        'The best match is ${describeUiNode(element, screen: screen)}, which '
        'covers the whole $screen screen. That is a scrim or a modal barrier, '
        'and tapping one dismisses whatever is in front of it. Name the '
        'control you want instead — if it has gone, the screen has moved on:\n'
        '${renderUiElements(interestingNodes(tree), screen: screen, limit: 60).listing}',
      );
    }
    if (screen != null && !bounds.centerIsOnScreen(screen)) {
      throw DeviceRefusal(
        'The matched element is off screen at ${bounds.raw} on a $screen '
        '${read.space.label} display — it is scrolled out of view. Scroll it '
        'into view first; tapping its centre would hit whatever is really at '
        'that point.',
      );
    }

    final point = bounds.center;
    await driver.tap(point.x, point.y);
    return uiTextBlock([
      'Tapped (${point.x}, ${point.y}) ${read.space.label} on '
          '${describeUiNode(element, screen: screen)}',
      ...?moved,
      'Device ${driver.target.id}, ${read.app ?? 'unknown app'}'
          '${matches.length == 1 ? '' : ', chosen from ${matches.length} matches'}'
          // The runner-up by name: reading "chosen from 2" is what tells you a
          // pick went wrong, and saying which one lost turns that into a
          // diagnosis without a second round trip.
          '${_runnerUp(matches, element, screen)}.'
          '${element.enabled ? '' : ' NOTE: this element is disabled.'}',
      'Take a screenshot or dump again to confirm what changed.',
    ]);
  }

  /// ` (also: …)` naming the best match that was not taken, or empty.
  String _runnerUp(
    List<UiNode> matches,
    UiNode chosen,
    DeviceScreenSize? screen,
  ) {
    for (final node in matches) {
      if (identical(node, chosen)) continue;
      return ' (also: ${describeUiNode(node, screen: screen)})';
    }
    return '';
  }
}

/// What the pre-tap check found, as the three fields the reply carries.
///
/// A record rather than a sentence because the three answer different
/// questions and an agent skims: what was checked, what is under the finger,
/// and what it should have called instead.
class _CoordinateCheck {
  const _CoordinateCheck({required this.verdict, this.under, this.prefer});

  /// What was compared against what, always said — including when the answer
  /// is "nothing was".
  final String verdict;

  /// The element the coordinate lands on.
  final String? under;

  /// The dynamic locator that would have found it. Null when the element has
  /// no name to be found by, which is itself the answer.
  final String? prefer;
}

/// **The locating policy, written once and spliced into every tool it governs.**
///
/// Stated on the tools themselves for the reason `mcp_tool_catalogue.dart`
/// gives for its four hints: a rule that lives in one file is a survey, and a
/// rule an agent meets at the moment it is choosing is a rule. It is the *same*
/// sentence on all four rather than four tailored variants, because four
/// wordings of one rule read as four hints.
///
/// The third sentence is the one that changes behaviour. "Prefer the robust
/// thing" loses to "the other one is faster" every time, and until
/// `device_tap` started reading the screen before it acted, the other one
/// genuinely was faster. It no longer is — counted, a vetted `device_tap` and
/// a `device_tap_element` are the same six adb invocations — so the policy can
/// state it as a fact rather than an exhortation.
const String kDeviceLocatingPolicy =
    'LOCATING POLICY — dynamic first, coordinates as a checked fallback. '
    'Prefer device_tap_element: it resolves the element against the screen as '
    'it is at the instant of the tap, so it survives a layout change, a '
    'different screen size and a scale factor, and it tells you what it hit. '
    'Use device_tap only when the dynamic attempt has failed, and only with '
    'coordinates you verified during exploration — device_ui_dump and '
    'device_find_elements report them in the space this device actually takes. '
    'There is no speed reason to skip the dynamic path: device_tap reads the '
    'screen before it acts, so the two cost the same, and device_tap is the '
    'one that gets refused when the screen has moved since you looked.';


/// The schemas for [DeviceDriveTools].
const Map<String, dynamic> deviceTapSchema = {
  'name': 'device_tap',
  'description':
      'Tap the screen at (x, y). On Android these are DEVICE PIXELS (the '
      'space list_devices reports as screen size, not the size of any '
      'screenshot you scaled). On an iOS simulator they are POINTS, which a '
      'screenshot is NOT in. Reads the screen immediately before it acts and '
      'refuses when the structure has changed since this app last read the '
      'device — a coordinate for a screen that is gone lands wherever the '
      'new one happens to put something. Pass verify: false for a surface '
      'with nothing in its hierarchy. $kDeviceLocatingPolicy',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'x': {'type': 'number'},
      'y': {'type': 'number'},
      'verify': {
        'type': 'boolean',
        'description':
            'Read the screen immediately before tapping and refuse if it has '
            'moved since it was last read. Default true. Pass false only for '
            'a surface with nothing in its hierarchy — a canvas, a game, a '
            'custom-painted view — where there is nothing for the check to '
            'be about; the reply then says the tap was sent unverified.',
      },
    },
    'required': ['x', 'y'],
  },
};

const Map<String, dynamic> deviceTypeSchema = {
  'name': 'device_type',
  'description':
      'Type text into whatever field currently has focus, on Android or on '
      'an iOS simulator. Tap the field first. Android escapes shell '
      'characters for you; iOS types through XCUITest, so anything the '
      'keyboard can produce travels as itself. Pass submit to press Enter '
      'after the text, which is what runs a command or sends a form.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'text': {'type': 'string'},
      'submit': {
        'type': 'boolean',
        'description':
            'Press Enter after typing. A real key press, not the keyboard\'s '
            'own action button, so it also reaches views that handle their '
            'own keys — a Flutter text field, an embedded terminal. The '
            'reply says submitted: true only when the key actually went.',
      },
    },
    'required': ['text'],
  },
};

const Map<String, dynamic> deviceKeySchema = {
  'name': 'device_key',
  'description':
      'Press a hardware button: back, home, recents, power, volumeUp, '
      'volumeDown, enter, tab or delete. All nine work on Android. On an iOS '
      'simulator home and power are real buttons, enter/tab/delete are typed '
      'into the focused field, and back/recents/volume are refused with a '
      'reason — iOS has no system back button and its app switcher cannot be '
      'reached by injected touches.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'key': {
        'type': 'string',
        'description':
            'back | home | recents | power | volumeUp | volumeDown | enter | '
            'tab | delete',
      },
    },
    'required': ['key'],
  },
};

const Map<String, dynamic> deviceTapElementSchema = {
  'name': 'device_tap_element',
  'description':
      'Tap the element matching a query rather than a coordinate — '
      'tap_element(text: "Sign in") instead of tap(357, 126). This is far '
      'more reliable: it survives layout changes, it cannot be off by a '
      'scale factor — which on iOS is a factor of three — and it tells you '
      'what it actually hit. It re-reads the hierarchy first, so it acts on '
      'the screen as it is now. Refuses rather than guessing when the query '
      'matches several elements (pass index) or nothing, and refuses to tap '
      'an element that is scrolled off screen. $kDeviceLocatingPolicy',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
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
};
