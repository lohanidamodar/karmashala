import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/devices/application/device_providers.dart';
import 'package:chitragupta/src/features/devices/domain/android_device.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

/// End-to-end tests of the three accessibility-tree MCP tools, driven the way
/// the bridge drives them: a real `POST /rpc` against a real
/// [LauncherControlServer], with adb faked underneath.
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

/// Starts a server wired to [runner] and returns a caller that speaks `/rpc`.
Future<
  ({
    Future<Map<String, dynamic>> Function(String, [Map<String, Object?>]) call,
    Future<void> Function() dispose,
  })
>
_server(FakeCommandRunner runner) async {
  final container = ProviderContainer(
    overrides: [
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: runner),
      ),
      androidSdkProvider.overrideWith((ref) => _sdk()),
    ],
  );
  // adbServiceProvider reads the SDK's AsyncValue, so it must have resolved
  // before the first tool call or every tool reports "no SDK found".
  await container.read(androidSdkProvider.future);
  final directory = await Directory.systemTemp.createTemp('cg_ui_tools');
  final bridgeFile = '${directory.path}${Platform.pathSeparator}bridge.json';
  final server = LauncherControlServer(container);
  await server.start(bridgeFilePath: bridgeFile);
  final handshake =
      jsonDecode(File(bridgeFile).readAsStringSync()) as Map<String, dynamic>;
  final port = handshake['port'] as int;
  final token = handshake['token'] as String;
  final client = HttpClient();

  Future<Map<String, dynamic>> call(
    String tool, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final request = await client.post('127.0.0.1', port, '/rpc');
    request.headers.set('authorization', 'Bearer $token');
    request.write(jsonEncode({'tool': tool, 'arguments': arguments}));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> dispose() async {
    client.close(force: true);
    await server.stop();
    container.dispose();
    await directory.delete(recursive: true);
  }

  return (call: call, dispose: dispose);
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
  group('tool registration', () {
    test('the three tree tools are advertised to the bridge', () {
      final names = [
        for (final schema in LauncherControlServer.toolSchemas)
          schema['name'] as String,
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
      for (final schema in LauncherControlServer.toolSchemas) {
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
}
