import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_host/src/mcp/tools/device_tool_set.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import 'support/device_rig.dart';

/// End-to-end tests of the three accessibility-tree MCP tools, run by the
/// server (slice 4a) the way an agent calls them, with adb faked underneath.
///
/// The XML below is the emulator's Settings screen, trimmed to the rows that
/// matter. It keeps the shapes that made this loop's decisions: `&amp;` in a
/// label, a row scrolled off the bottom, and a title that is also a substring
/// of another element.
const _dumpXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" class="android.widget.FrameLayout" '
    'package="com.android.settings" bounds="[0,0][1080,2400]">'
    '<node index="0" text="Settings" resource-id="com.android.settings:id/title" '
    'class="android.widget.TextView" package="com.android.settings" '
    'clickable="false" enabled="true" bounds="[66,300][400,400]" />'
    '<node index="1" text="Search settings" '
    'resource-id="com.android.settings:id/search_action_bar_title" '
    'class="android.widget.TextView" package="com.android.settings" '
    'clickable="true" enabled="true" bounds="[66,500][1014,620]" />'
    '<node index="2" class="android.widget.LinearLayout" '
    'package="com.android.settings" clickable="true" enabled="true" '
    'bounds="[0,700][1080,900]">'
    '<node index="0" text="Network &amp; internet" '
    'resource-id="android:id/title" class="android.widget.TextView" '
    'package="com.android.settings" enabled="true" '
    'bounds="[132,740][600,860]" />'
    '</node>'
    '<node index="3" text="Off the bottom" class="android.widget.TextView" '
    'package="com.android.settings" clickable="true" enabled="true" '
    'bounds="[0,2600][1080,2760]" />'
    '<node index="4" class="android.widget.Switch" '
    'package="com.android.settings" content-desc="Wi-Fi" checkable="true" '
    'checked="true" clickable="true" enabled="true" '
    'bounds="[900,740][1014,860]" />'
    '</node>'
    '</hierarchy>';

const _sdkRoot = r'C:\sdk';
const _adbPath = r'C:\sdk\platform-tools\adb.exe';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows-native', path: _sdkRoot),
  adb: EnvironmentPath(environmentId: 'windows-native', path: _adbPath),
);

/// One adb stand-in that answers everything these tools ask for.
FakeCommandRunner _adbRunner({String dumpXml = _dumpXml}) => FakeCommandRunner(
  responder: (request) {
    final args = request.arguments;
    if (args.contains('devices')) {
      return const CommandResult(
        exitCode: 0,
        stdout:
            'List of devices attached\n'
            'emulator-5554  device product:sdk model:Pixel transport_id:7\n',
        stderr: '',
      );
    }
    if (args.contains('wm')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'Physical size: 1080x2400',
        stderr: '',
      );
    }
    if (args.contains('uiautomator')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'UI hierchary dumped to: /data/local/tmp/x.xml',
        stderr: '',
      );
    }
    if (args.contains('cat')) {
      return CommandResult(exitCode: 0, stdout: dumpXml, stderr: '');
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  },
);

/// The server's device tools wired to [runner], and a caller.
Future<
  ({
    Future<Map<String, dynamic>> Function(String, [Map<String, Object?>]) call,
    Future<void> Function() dispose,
  })
>
_server(FakeCommandRunner runner) async {
  final rig = DeviceRig(runner: runner, sdk: _sdk());
  return (
    call: (String tool, [Map<String, Object?> arguments = const {}]) =>
        rig.call(tool, arguments),
    dispose: rig.dispose,
  );
}

/// The text of an `_mcpContent` reply — these tools return one text block
/// rather than a JSON map, because the bridge pretty-prints maps and one JSON
/// object per node costs several times what one line per node does.
String _text(Map<String, dynamic> reply) {
  expect(reply['ok'], isTrue, reason: 'RPC failed: ${reply['error']}');
  final content = (reply['result'] as Map)['_mcpContent'] as List;
  return (content.single as Map)['text'] as String;
}

String _error(Map<String, dynamic> reply) {
  expect(
    reply['ok'],
    isFalse,
    reason: 'expected a failure, got ${reply['result']}',
  );
  return reply['error'] as String;
}

void main() {
  _fieldReportFixes();

  group('tool registration', () {
    test('the three tree tools are advertised to the bridge', () {
      final names = [
        for (final schema in deviceToolSchemas) schema['name'] as String,
      ];
      expect(
        names,
        containsAll(<String>[
          'device_ui_dump',
          'device_find_elements',
          'device_tap_element',
        ]),
      );
      // Loop 27's tools must still be there — this file is shared.
      expect(
        names,
        containsAll(<String>[
          'list_devices',
          'device_screenshot',
          'device_tap',
          'device_type',
          'device_key',
          'device_logcat',
        ]),
      );
    });

    test('every schema is a well-formed object schema', () {
      for (final schema in deviceToolSchemas) {
        expect(schema['description'], isA<String>());
        final input = schema['inputSchema'] as Map<String, dynamic>;
        expect(input['type'], 'object');
        expect(input['properties'], isA<Map<String, dynamic>>());
      }
    });
  });

  group('device_ui_dump', () {
    test('lists the useful nodes with a tap point each', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(await server.call('device_ui_dump'));

      expect(text, contains('emulator-5554'));
      expect(text, contains('com.android.settings'));
      expect(text, contains('screen 1080x2400 device px'));
      // Centre of [132,740][600,860].
      expect(text, contains('(366,800) 468x120 TextView "Network & internet"'));
      expect(text, contains('#title'));
      // The Switch is identified by content-desc and its state is visible.
      expect(text, contains('~"Wi-Fi"'));
      expect(text, contains('[ckK]'));
    });

    test('drops the layout scaffolding by default', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(await server.call('device_ui_dump'));
      expect(text, isNot(contains('FrameLayout')));
      expect(text, contains('6 of 7 nodes (text-bearing or interactable)'));
    });

    test('full=true shows every node as an indented tree', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(await server.call('device_ui_dump', {'full': true}));
      expect(text, contains('Full UI hierarchy'));
      expect(text, contains('FrameLayout'));
      expect(text, contains('  (366,800)'));
    });

    test('filter narrows the listing', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(
        await server.call('device_ui_dump', {'filter': 'network'}),
      );
      expect(text, contains('Network & internet'));
      expect(text, isNot(contains('Search settings')));
    });

    test('limit says how many it left out', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(await server.call('device_ui_dump', {'limit': 2}));
      expect(text, contains('more not shown'));
    });

    test('an off-screen row is flagged, not silently listed', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(await server.call('device_ui_dump'));
      final line = text
          .split('\n')
          .firstWhere((l) => l.contains('Off the bottom'));
      expect(line, contains('o]'));
    });

    test(
      'explains an idle-state failure instead of returning nothing',
      () async {
        final server = await _server(
          FakeCommandRunner(
            responder: (request) {
              if (request.arguments.contains('devices')) {
                return const CommandResult(
                  exitCode: 0,
                  stdout: 'emulator-5554\tdevice\n',
                  stderr: '',
                );
              }
              if (request.arguments.contains('uiautomator')) {
                // Note the exit code: uiautomator fails while succeeding.
                return const CommandResult(
                  exitCode: 0,
                  stdout: 'ERROR: could not get idle state.',
                  stderr: '',
                );
              }
              return const CommandResult(exitCode: 0, stdout: '', stderr: '');
            },
          ),
        );
        addTearDown(server.dispose);
        final error = _error(await server.call('device_ui_dump'));
        expect(error, contains('idle'));
        expect(error, contains('emulator-5554'));
      },
    );
  });

  group('device_find_elements', () {
    test('finds by text and ranks the exact match first', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(
        await server.call('device_find_elements', {'text': 'settings'}),
      );
      final lines = text.split('\n').where((l) => l.startsWith('(')).toList();
      expect(lines.first, contains('"Settings"'));
      expect(lines.length, 2);
      expect(text, contains('2 elements match'));
    });

    test('finds by resource id, short form included', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(
        await server.call('device_find_elements', {'resourceId': 'title'}),
      );
      expect(text, contains('"Settings"'));
    });

    test(
      'finds by content-description, which is where Flutter puts labels',
      () async {
        final server = await _server(_adbRunner());
        addTearDown(server.dispose);
        final text = _text(
          await server.call('device_find_elements', {'contentDesc': 'Wi-Fi'}),
        );
        expect(text, contains('Switch'));
      },
    );

    test('clickable=true filters out inert text', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(
        await server.call('device_find_elements', {
          'text': 'Network',
          'clickable': true,
        }),
      );
      expect(text, contains('No element matches'));
    });

    test('a miss shows what is on screen instead of an empty answer', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final text = _text(
        await server.call('device_find_elements', {'text': 'Bluetooth'}),
      );
      expect(text, contains('No element matches'));
      expect(text, contains('What is on screen instead'));
      expect(text, contains('Network & internet'));
    });

    test(
      'refuses an empty query rather than returning the whole tree',
      () async {
        final server = await _server(_adbRunner());
        addTearDown(server.dispose);
        expect(
          _error(await server.call('device_find_elements')),
          contains('at least one of'),
        );
      },
    );
  });

  group('device_tap_element', () {
    test('taps the centre of the matched element in device pixels', () async {
      final runner = _adbRunner();
      final server = await _server(runner);
      addTearDown(server.dispose);
      final text = _text(
        await server.call('device_tap_element', {'text': 'Network & internet'}),
      );

      final tap = runner.requests.lastWhere(
        (r) => r.arguments.contains('input'),
      );
      // Centre of [132,740][600,860] — the row's own rectangle, not its
      // clickable parent's, whose centre is a different point entirely.
      expect(tap.arguments, [
        '-s',
        'emulator-5554',
        'shell',
        'input',
        'tap',
        '366',
        '800',
      ]);
      expect(text, contains('Tapped (366, 800)'));
      expect(text, contains('"Network & internet"'));
    });

    test('re-reads the hierarchy before tapping', () async {
      final runner = _adbRunner();
      final server = await _server(runner);
      addTearDown(server.dispose);
      await server.call('device_tap_element', {'text': 'Network & internet'});
      final dumpIndex = runner.requests.indexWhere(
        (r) => r.arguments.contains('uiautomator'),
      );
      final tapIndex = runner.requests.indexWhere(
        (r) => r.arguments.contains('input'),
      );
      expect(dumpIndex, greaterThanOrEqualTo(0));
      expect(tapIndex, greaterThan(dumpIndex));
    });

    test('an unambiguous exact match wins over its substrings', () async {
      final runner = _adbRunner();
      final server = await _server(runner);
      addTearDown(server.dispose);
      // "Settings" also matches "Search settings"; the exact one is meant.
      final text = _text(
        await server.call('device_tap_element', {'text': 'Settings'}),
      );
      expect(text, contains('Tapped (233, 350)'));
      expect(text, contains('chosen from 2 matches'));
    });

    test('refuses an ambiguous query instead of guessing', () async {
      final runner = _adbRunner();
      final server = await _server(runner);
      addTearDown(server.dispose);
      final error = _error(
        await server.call('device_tap_element', {'text': 'e'}),
      );
      expect(error, contains('Pass index to choose'));
      expect(error, contains('[0]'));
      expect(
        runner.requests.where((r) => r.arguments.contains('input')),
        isEmpty,
        reason: 'nothing may be tapped when the choice is ambiguous',
      );
    });

    test('index picks one of several matches', () async {
      final runner = _adbRunner();
      final server = await _server(runner);
      addTearDown(server.dispose);
      _text(await server.call('device_tap_element', {'text': 'e', 'index': 0}));
      expect(
        runner.requests.where((r) => r.arguments.contains('input')),
        hasLength(1),
      );
    });

    test('refuses to tap something scrolled off screen', () async {
      final runner = _adbRunner();
      final server = await _server(runner);
      addTearDown(server.dispose);
      final error = _error(
        await server.call('device_tap_element', {'text': 'Off the bottom'}),
      );
      expect(error, contains('off screen'));
      expect(error, contains('[0,2600][1080,2760]'));
      expect(
        runner.requests.where((r) => r.arguments.contains('input')),
        isEmpty,
      );
    });

    test('a miss lists the screen so the next attempt can succeed', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      final error = _error(
        await server.call('device_tap_element', {'text': 'Bluetooth'}),
      );
      expect(error, contains('Nothing matches'));
      expect(error, contains('Network & internet'));
    });

    test('rejects an out-of-range index', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      expect(
        _error(
          await server.call('device_tap_element', {
            'text': 'Settings',
            'index': 9,
          }),
        ),
        contains('out of range'),
      );
    });
  });

  group('device_stop_emulator', () {
    test('is advertised alongside the other device tools', () {
      final names = [
        for (final schema in deviceToolSchemas) schema['name'] as String,
      ];
      expect(names, contains('device_stop_emulator'));
    });

    test('requires a serial rather than guessing the only device', () async {
      // Every other device tool defaults to "the only ready device". Silently
      // defaulting a destructive action is a different thing entirely.
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);
      expect(
        _error(await server.call('device_stop_emulator')),
        contains('serial is required'),
      );
    });

    test(
      'refuses a physical device, which cannot be stopped this way',
      () async {
        final runner = FakeCommandRunner(
          responder: (request) => request.arguments.contains('devices')
              ? const CommandResult(
                  exitCode: 0,
                  stdout:
                      'List of devices attached\n'
                      'F6IZLV6LMFT4U4ZT device product:CPH1989 model:CPH1989\n',
                  stderr: '',
                )
              : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
        );
        final server = await _server(runner);
        addTearDown(server.dispose);
        final error = _error(
          await server.call('device_stop_emulator', {
            'serial': 'F6IZLV6LMFT4U4ZT',
          }),
        );
        expect(error, contains('physical device'));
      },
    );

    test('kills the emulator and confirms it really went', () async {
      var polls = 0;
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('devices')) {
            polls += 1;
            return CommandResult(
              exitCode: 0,
              stdout: polls <= 1
                  ? 'List of devices attached\nemulator-5554 device\n'
                  : 'List of devices attached\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: 'OK\n', stderr: '');
        },
      );
      final server = await _server(runner);
      addTearDown(server.dispose);
      final reply = await server.call('device_stop_emulator', {
        'serial': 'emulator-5554',
      });
      expect(reply['ok'], isTrue, reason: '${reply['error']}');
      expect((reply['result'] as Map)['stopped'], isTrue);
      expect(
        runner.requests.map((r) => r.arguments),
        contains(equals(['-s', 'emulator-5554', 'emu', 'kill'])),
      );
    });
  });
}

/// A modal dialog over Android's full-screen barrier.
///
/// The shape from the field report: the barrier is a clickable node called
/// `Dismiss` spanning the display, sitting directly behind the button somebody
/// asked for. Tapping it closes the dialog and destroys the state under test.
const _scrimXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" class="android.widget.FrameLayout" '
    'package="com.example.app" bounds="[0,0][1080,2400]">'
    '<node index="0" content-desc="Dismiss" class="android.view.View" '
    'package="com.example.app" clickable="true" enabled="true" '
    'bounds="[0,0][1080,2400]" />'
    '<node index="1" text="Trust and connect" class="android.widget.Button" '
    'package="com.example.app" clickable="true" enabled="true" '
    'bounds="[640,1820][1080,1970]" />'
    '</node>'
    '</hierarchy>';

/// A Flutter terminal: one big painted view that reports no text at all.
const _canvasXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" class="android.widget.FrameLayout" '
    'package="com.example.app" bounds="[0,0][1080,2400]">'
    '<node index="0" content-desc="Back" class="android.widget.Button" '
    'package="com.example.app" clickable="true" enabled="true" '
    'bounds="[20,180][148,280]" />'
    '<node index="1" class="android.view.View" package="com.example.app" '
    'enabled="true" bounds="[0,320][1080,2260]" />'
    '</node>'
    '</hierarchy>';

void _fieldReportFixes() {
  group('device_type submit', () {
    test(
      'presses a real Enter, so a view that handles its own keys gets it',
      () async {
        // The field report: `submit: true` was accepted, the reply said
        // "typed", and nothing ran — the parameter did not exist, so it was
        // dropped in silence. An IME action would not have been enough either:
        // a Flutter TextInputClient or an embedded terminal receives committed
        // text but never the action.
        final runner = _adbRunner();
        final server = await _server(runner);
        addTearDown(server.dispose);

        final reply = await server.call('device_type', {
          'serial': 'emulator-5554',
          'text': 'uname -s',
          'submit': true,
        });
        expect(reply['ok'], isTrue, reason: '${reply['error']}');
        final result = reply['result'] as Map;
        expect(result['submitted'], isTrue);

        final sent = runner.requests
            .map((r) => r.arguments.join(' '))
            .where((a) => a.contains('input'))
            .toList();
        expect(
          sent.any(
            (a) => a.contains('keyevent') && a.contains('KEYCODE_ENTER'),
          ),
          isTrue,
          reason: 'expected a real key press, not an IME action; sent: $sent',
        );
      },
    );

    test('and says nothing about submitting when it was not asked', () async {
      final server = await _server(_adbRunner());
      addTearDown(server.dispose);

      final reply = await server.call('device_type', {
        'serial': 'emulator-5554',
        'text': 'uname -s',
      });
      expect((reply['result'] as Map).containsKey('submitted'), isFalse);
    });
  });

  test('device_tap_element refuses a full-screen scrim', () async {
    final server = await _server(_adbRunner(dumpXml: _scrimXml));
    addTearDown(server.dispose);

    final error = _error(
      await server.call('device_tap_element', {
        'serial': 'emulator-5554',
        'contentDesc': 'Dismiss',
      }),
    );
    expect(error, contains('covers the whole'));
    expect(
      error,
      contains('Trust and connect'),
      reason: 'the listing should show what is actually on screen',
    );
  });

  test('device_tap_element names the runner-up it did not take', () async {
    final server = await _server(_adbRunner());
    addTearDown(server.dispose);

    // "Settings" is also a substring of "Search settings", so this tap is
    // chosen from two. Reading which one lost is how a bad pick gets
    // diagnosed without a second round trip.
    final text = _text(
      await server.call('device_tap_element', {
        'serial': 'emulator-5554',
        'text': 'Settings',
      }),
    );
    expect(text, contains('chosen from 2 matches'));
    expect(text, contains('also:'));
    expect(text, contains('Search settings'));
  });

  test(
    'device_ui_dump says when the screen is painted, not composed',
    () async {
      final server = await _server(_adbRunner(dumpXml: _canvasXml));
      addTearDown(server.dispose);

      final text = _text(
        await server.call('device_ui_dump', {'serial': 'emulator-5554'}),
      );
      // Without this the dump reads like a success — "2 of 3 nodes" — rather
      // than a blind spot, and the next move is to dump again.
      expect(text, contains('custom-painted'));
      expect(text, contains('device_screenshot'));
    },
  );

  test('and stays quiet on a screen that really is made of widgets', () async {
    final server = await _server(_adbRunner());
    addTearDown(server.dispose);

    final text = _text(
      await server.call('device_ui_dump', {'serial': 'emulator-5554'}),
    );
    expect(text, isNot(contains('custom-painted')));
  });
}
