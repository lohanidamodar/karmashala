import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_tools.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_mcp/catalogue.dart';

import '../../support/fakes.dart';
import 'fake_vm_service.dart';

void main() {
  late Directory temp;
  late Map<String, FakeVmService> reachable;
  late ProviderContainer container;
  late FlutterAppTools tools;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('karmashala-flutter-tools');
    reachable = <String, FakeVmService>{};
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 9, 8))),
        flutterAppDiscoveryDirectoryProvider.overrideWith(
          (ref) async => VmServiceUriDirectory(temp),
        ),
        // This test knows about no tooling daemons. Without it the real
        // ones on the machine running the suite are read, and a live
        // `flutter run` in another window becomes an extra row.
        dtdPidFilesProvider.overrideWithValue(const DtdPidFiles(null)),
        vmServiceConnectorProvider.overrideWithValue((uri) async {
          final fake = reachable[uri.toString()];
          if (fake == null) throw const _Refused();
          return fake.client;
        }),
      ],
    );
    tools = FlutterAppTools(container);
  });

  tearDown(() {
    container.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  FakeVmService serve(String wsUri, {Map<String, Object?>? selectedWidget}) =>
      reachable[wsUri] = FakeVmService(selectedWidget: selectedWidget);

  void writeUriFile(String name, String wsUri) =>
      File('${temp.path}${Platform.pathSeparator}$name')
          .writeAsStringSync(wsUri);

  String textOf(Object? result) {
    final content = (result as Map)['_mcpContent'] as List;
    return (content.first as Map)['text'] as String;
  }

  group('the tool surface', () {
    const names = <String>[
      'flutter_apps',
      'flutter_attach',
      'flutter_reload',
      'flutter_logs',
      'flutter_pick_widget',
    ];

    test('every schema is a well-formed object schema', () {
      expect(
        flutterAppToolSchemas.map((schema) => schema['name']),
        unorderedEquals(names),
      );
      for (final schema in flutterAppToolSchemas) {
        expect(schema['description'], isA<String>());
        expect(schema['inputSchema']['type'], 'object');
        expect(schema['inputSchema']['properties'], isA<Map<String, dynamic>>());
      }
    });

    test('the handler answers to exactly the names it declares', () {
      for (final name in names) {
        expect(FlutterAppTools.handles(name), isTrue, reason: name);
      }
      expect(FlutterAppTools.handles('browser_pick'), isFalse);
      expect(FlutterAppTools.handles('device_tap'), isFalse);
    });

    test('all five are served, and each says what it does', () {
      final served = <String>{
        for (final schema in LauncherControlServer.toolSchemas)
          schema['name'] as String,
      };
      expect(served.intersection(names.toSet()), names.toSet());
      for (final name in names) {
        expect(kMcpToolAnnotations[name], isNotNull, reason: name);
      }
      // A restart ends the app's state, and the annotation describes the worse
      // case of the one tool that can do it.
      expect(kMcpToolAnnotations['flutter_reload']!.destructive, isTrue);
      expect(kMcpToolAnnotations['flutter_apps']!.readOnly, isTrue);
    });

    // The schemas being served proves the catalogue; only a call proves the
    // dispatch arm. Over `/rpc`, so the name is resolved by the registry the
    // bridge actually talks to rather than by `FlutterAppTools` directly — an
    // unregistered arm answers "Unknown tool" here.
    test('a name resolves through the real registry', () async {
      final bridge = File(
        '${temp.path}${Platform.pathSeparator}bridge.json',
      ).path;
      final server = LauncherControlServer(container);
      await server.start(bridgeFilePath: bridge, useLocalSocket: false);
      final client = HttpClient();
      try {
        final handshake =
            jsonDecode(File(bridge).readAsStringSync())
                as Map<String, Object?>;
        final request = await client.post(
          '127.0.0.1',
          handshake['port']! as int,
          '/rpc',
        );
        request.headers.set(
          'authorization',
          'Bearer ${handshake['token']! as String}',
        );
        request.write(
          jsonEncode({'tool': 'flutter_apps', 'arguments': <String, Object?>{}}),
        );
        final reply =
            jsonDecode(await utf8.decoder.bind(await request.close()).join())
                as Map<String, Object?>;
        expect(reply['ok'], isTrue, reason: 'RPC failed: ${reply['error']}');
        expect(
          (reply['result']! as Map)['howToMakeOneVisible'],
          contains('found on their own'),
        );
      } finally {
        client.close(force: true);
        await server.stop();
      }
    });
  });

  group('flutter_apps', () {
    test('an empty answer says what is looked at, not what to add', () async {
      final result = await tools.call('flutter_apps', {}) as Map;
      expect(result['summary'], 'No Flutter app is running that we can see.');
      expect(result['apps'], isEmpty);
      expect(result['howToMakeOneVisible'], contains('found on their own'));
      expect(result['howToMakeOneVisible'], isNot(contains('--vmservice-out-file')));
      expect(result['checkedAt'], isNotNull);
    });

    test('reports each app with an id, and whether it can be reloaded', () async {
      const uri = 'ws://127.0.0.1:53119/tok=/ws';
      final fake = serve(uri);
      writeUriFile('windows.uri', uri);

      var result = await tools.call('flutter_apps', {}) as Map;
      var app = (result['apps'] as List).single as Map;
      expect(app['reachability'], 'attached');
      expect(app['canHotReload'], isFalse);
      expect(app['widgetLocations'], 'tracked');
      expect(result['howToMakeOneVisible'], isNull);

      fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await pumpEventQueue();
      result = await tools.call('flutter_apps', {}) as Map;
      app = (result['apps'] as List).single as Map;
      expect(app['canHotReload'], isTrue);
    });

    test('an address nothing answers on is reported, not hidden', () async {
      writeUriFile('stale.uri', 'ws://127.0.0.1:9/gone=/ws');
      final result = await tools.call('flutter_apps', {}) as Map;
      final app = (result['apps'] as List).single as Map;
      expect(app['reachability'], 'unreachable');
      expect(app['detail'], contains('Nothing answered'));
      expect(result['howToMakeOneVisible'], isNotNull);
    });
  });

  group('flutter_attach', () {
    test('takes the printed address', () async {
      serve('ws://127.0.0.1:53119/tok=/ws');
      final result =
          await tools.call('flutter_attach', {
                'vmServiceUri': 'http://127.0.0.1:53119/tok=/',
              })
              as Map;
      expect((result['attached'] as Map)['reachability'], 'attached');
    });

    test('a missing address is refused with the remedy', () async {
      await expectLater(
        tools.call('flutter_attach', {}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('found on their own'),
          ),
        ),
      );
    });
  });

  group('flutter_reload', () {
    test('says what it proved and what it did not', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      await tools.call('flutter_attach', {'vmServiceUri': uri});
      fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await pumpEventQueue();

      final result = await tools.call('flutter_reload', {}) as Map;
      expect(result['kind'], 'hotReload');
      expect(result['accepted'], isTrue);
      expect(result['note'], contains('flutter_logs'));
      expect(fake.methods, contains('s1.reloadSources'));
    });

    test('a restart says the app lost its state', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      await tools.call('flutter_attach', {'vmServiceUri': uri});
      fake.emitServiceRegistered('hotRestart', 's1.hotRestart');
      await pumpEventQueue();

      final result =
          await tools.call('flutter_reload', {'fullRestart': true}) as Map;
      expect(result['kind'], 'hotRestart');
      expect(result['note'], contains('lost the state'));
    });

    test('an app with no tool attached is told why, not just refused', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      serve(uri);
      await tools.call('flutter_attach', {'vmServiceUri': uri});
      await expectLater(
        tools.call('flutter_reload', {}),
        throwsA(
          predicate<Object>(
            (error) => '$error'.contains('no Flutter tool is attached'),
            'explains that the recompile comes from the tool',
          ),
        ),
      );
    });
  });

  group('flutter_logs', () {
    test('is prose, with the origin of every line', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      await tools.call('flutter_attach', {'vmServiceUri': uri});
      fake.emitStdout('flutter: hello\n');
      fake.emitStdout('bad\n', stderr: true);
      fake.emitDeveloperLog('a record', loggerName: 'app.net');
      fake.emitFlutterError(flutterErrorTree());
      await pumpEventQueue();

      final text = textOf(await tools.call('flutter_logs', {}));
      expect(text, contains('[out] flutter: hello'));
      expect(text, contains('[err] bad'));
      expect(text, contains('[log app.net] a record'));
      expect(text, contains('[ERROR] The following StateError was thrown'));
      expect(text, contains('Bad state: broken'));
    });

    test('errorsOnly leaves the chatter out', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      await tools.call('flutter_attach', {'vmServiceUri': uri});
      fake.emitStdout('chatter\n');
      fake.emitStdout('bad\n', stderr: true);
      await pumpEventQueue();

      final text = textOf(await tools.call('flutter_logs', {'errorsOnly': true}));
      expect(text, contains('bad'));
      expect(text, isNot(contains('chatter')));
    });

    test('says an empty tail is only since the attach', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      serve(uri);
      await tools.call('flutter_attach', {'vmServiceUri': uri});
      final text = textOf(
        await tools.call('flutter_logs', {'errorsOnly': true}),
      );
      expect(text, contains('not the same as it having said nothing at all'));
    });

    test('marks replayed history rather than presenting it as now', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      await tools.call('flutter_attach', {'vmServiceUri': uri});
      fake.emitStdout('startup\n', at: DateTime.utc(2026, 9, 7));
      await pumpEventQueue();
      final text = textOf(await tools.call('flutter_logs', {}));
      expect(text, contains('(before attach) startup'));
    });
  });

  group('flutter_pick_widget', () {
    test('introduces the widget as the developer\'s choice', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(
        uri,
        selectedWidget: const <String, Object?>{
          'description': 'ElevatedButton',
          'creationLocation': <String, Object?>{
            'file': 'file:///C:/app/lib/main.dart',
            'line': 118,
            'column': 22,
          },
          'createdByLocalProject': true,
        },
      );
      await tools.call('flutter_attach', {'vmServiceUri': uri});

      final pick = tools.call('flutter_pick_widget', {'timeoutSeconds': 5});
      await pumpEventQueue();
      fake.emitNavigate(line: 118, column: 22);
      final text = textOf(await pick);

      expect(text, startsWith('The developer pointed at this widget'));
      expect(text, contains('Flutter '));
      expect(text, contains('ElevatedButton'));
      expect(text, contains('main.dart:118:22'));
    });

    test('a build with no widget locations says so instead of showing nothing', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(
        uri,
        selectedWidget: const <String, Object?>{'description': 'Text'},
      );
      fake.handlers['ext.flutter.inspector.isWidgetCreationTracked'] =
          (_) => <String, Object?>{'type': '_extensionType', 'result': false};
      await tools.call('flutter_attach', {'vmServiceUri': uri});

      final pick = tools.call('flutter_pick_widget', {'timeoutSeconds': 5});
      await pumpEventQueue();
      fake.emitNavigate();
      final text = textOf(await pick);

      expect(text, contains('without --track-widget-creation'));
      expect(text, contains('Text'));
    });
  });

  group('choosing an app', () {
    test('two attached apps are refused by name', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      serve('ws://127.0.0.1:2/b=/ws');
      await tools.call('flutter_attach', {'vmServiceUri': 'ws://127.0.0.1:1/a=/ws'});
      await tools.call('flutter_attach', {'vmServiceUri': 'ws://127.0.0.1:2/b=/ws'});
      await expectLater(
        tools.call('flutter_logs', {}),
        throwsA(
          predicate<Object>(
            (error) => '$error'.contains('More than one Flutter app'),
            'names the ambiguity',
          ),
        ),
      );
    });

    test('an id from a finished run is refused, not resolved to another app', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      await tools.call('flutter_attach', {'vmServiceUri': 'ws://127.0.0.1:1/a=/ws'});
      await expectLater(
        tools.call('flutter_logs', {'appId': '127.0.0.1:9/old='}),
        throwsA(
          predicate<Object>(
            (error) => '$error'.contains('lasts only as long as the run'),
            'explains why the id is gone',
          ),
        ),
      );
    });
  });
}

class _Refused implements Exception {
  const _Refused();
  @override
  String toString() => 'Connection refused';
}
