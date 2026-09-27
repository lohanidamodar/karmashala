import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_host/src/flutter/attached_apps.dart';
import 'package:karmashala_host/src/flutter/flutter_logs_source.dart';
import 'package:test/test.dart';

import 'fake_vm_service.dart';

void main() {
  late Directory temp;
  late Map<String, FakeVmService> reachable;
  late ServerAttachedApps apps;
  late List<FlutterAppRegistry> told;
  final at = DateTime.utc(2026, 9, 8, 12);

  File writeUriFile(String name, String wsUri) =>
      File('${temp.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync(wsUri);

  FakeVmService serve(String wsUri, {Map<String, Object?>? selectedWidget}) =>
      reachable[wsUri] = FakeVmService(selectedWidget: selectedWidget);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('karmashala-vmservice-test');
    reachable = {};
    told = [];
    apps = ServerAttachedApps(
      directory: VmServiceUriDirectory(temp),
      dtdPidFiles: const DtdPidFiles([]),
      connect: (uri) async {
        final fake = reachable[uri.toString()];
        if (fake == null) throw const SocketException('Connection refused');
        return fake.client;
      },
      clock: () => at,
      onChanged: told.add,
    );
  });

  tearDown(() async {
    await apps.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  FlutterAppRegistry registry() => apps.registry;

  group('discovery', () {
    test('nothing has been looked for until something looks', () {
      expect(registry().hasLooked, isFalse);
      expect(
        describeRegistry(registry()),
        'We have not looked for a running Flutter app yet.',
      );
    });

    test('finds and attaches to what flutter run left, and tells', () async {
      const uri = 'ws://127.0.0.1:53119/tok=/ws';
      serve(uri);
      writeUriFile('windows.uri', uri);
      await apps.look();
      final app = registry().apps.single;
      expect(app.reachability, AppReachability.attached);
      expect(app.discovery, AppDiscovery.uriFile);
      expect(app.label, 'windows');
      expect(describeRegistry(registry()), '1 Flutter app attached.');
      expect(told.last.attached, hasLength(1));
    });

    test('holds several apps at once', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      serve('ws://127.0.0.1:2/b=/ws');
      writeUriFile('windows.uri', 'ws://127.0.0.1:1/a=/ws');
      writeUriFile('pixel.uri', 'ws://127.0.0.1:2/b=/ws');
      await apps.look();
      expect(registry().attached, hasLength(2));
      expect(describeRegistry(registry()), '2 Flutter apps attached.');
    });

    test('a file nothing answers on is on record, not deleted', () async {
      writeUriFile('stale.uri', 'ws://127.0.0.1:9/gone=/ws');
      await apps.look();
      final app = registry().apps.single;
      expect(app.reachability, AppReachability.unreachable);
      expect(app.detail, contains('Nothing answered on that address'));
      expect(File('${temp.path}/stale.uri').existsSync(), isTrue);
    });

    test('a file that is not an address is ignored', () async {
      writeUriFile('notes.txt', 'remember to buy milk');
      await apps.look();
      expect(registry().apps, isEmpty);
    });

    test('an attached app is not re-handshaked by a second look', () async {
      const uri = 'ws://127.0.0.1:53119/tok=/ws';
      final fake = serve(uri);
      writeUriFile('windows.uri', uri);
      await apps.look();
      final handshakes = fake.methods.where((m) => m == 'getVM').length;
      await apps.look();
      expect(fake.methods.where((m) => m == 'getVM').length, handshakes);
    });

    test('a removed file drops its row', () async {
      final file = writeUriFile('stale.uri', 'ws://127.0.0.1:9/gone=/ws');
      await apps.look();
      file.deleteSync();
      await apps.look();
      expect(registry().apps, isEmpty);
    });

    test('the remedy names what is found on its own', () {
      expect(apps.attachHint, isNot(contains('--vmservice-out-file')));
      expect(apps.attachHint, contains('found on their own'));
      expect(apps.attachHint, contains('another machine'));
    });
  });

  group('attaching', () {
    test('takes the address flutter run prints, by hand', () async {
      serve('ws://127.0.0.1:53119/tok=/ws');
      final app = await apps.attach('http://127.0.0.1:53119/tok=/');
      expect(app.reachability, AppReachability.attached);
      expect(app.discovery, AppDiscovery.byHand);
    });

    test('a device serial makes it a device-log row', () async {
      serve('ws://127.0.0.1:40000/tok=/ws');
      final app = await apps.attach(
        'http://127.0.0.1:40000/tok=/',
        deviceSerial: 'emulator-5554',
      );
      expect(app.discovery, AppDiscovery.deviceLog);
      expect(app.sourcePath, 'emulator-5554');
      expect(app.label, 'emulator-5554');
    });

    test('is idempotent', () async {
      const uri = 'ws://127.0.0.1:53119/tok=/ws';
      final fake = serve(uri);
      await apps.attach(uri);
      await apps.attach(uri);
      expect(fake.methods.where((m) => m == 'getVM'), hasLength(1));
      expect(registry().apps, hasLength(1));
    });

    test('refuses something that is not an address', () async {
      await expectLater(
        apps.attach('the app on my phone'),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.badUri,
          ),
        ),
      );
    });

    test('says nothing answered rather than pretending', () async {
      await expectLater(
        apps.attach('ws://127.0.0.1:9/gone=/ws'),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.connectFailed,
          ),
        ),
      );
      expect(registry().apps.single.reachability, AppReachability.unreachable);
    });
  });

  group('choosing which app', () {
    test('one attached app needs no argument', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      await apps.attach('ws://127.0.0.1:1/a=/ws');
      expect(apps.requireApp(null).uri.port, 1);
    });

    test('two attached apps are refused by name', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      serve('ws://127.0.0.1:2/b=/ws');
      await apps.attach('ws://127.0.0.1:1/a=/ws');
      await apps.attach('ws://127.0.0.1:2/b=/ws');
      expect(
        () => apps.requireApp(null),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.ambiguousApp,
          ),
        ),
      );
    });

    test('nothing attached carries the remedy', () async {
      await apps.look();
      expect(
        () => apps.requireApp(null),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.message,
            'message',
            contains('found on their own'),
          ),
        ),
      );
    });

    test('an id from an ended run is not swapped', () {
      expect(
        () => apps.requireApp('127.0.0.1:1/old='),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.unknownApp,
          ),
        ),
      );
    });
  });

  group('hot reload', () {
    test('goes to the app that was named', () async {
      final first = serve('ws://127.0.0.1:1/a=/ws');
      final second = serve('ws://127.0.0.1:2/b=/ws');
      final a = await apps.attach('ws://127.0.0.1:1/a=/ws');
      await apps.attach('ws://127.0.0.1:2/b=/ws');
      first.emitServiceRegistered('reloadSources', 's1.reloadSources');
      second.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await pumpEventQueue();
      await apps.hotReload(a.id);
      expect(first.methods, contains('s1.reloadSources'));
      expect(second.methods, isNot(contains('s1.reloadSources')));
    });

    test('the row learns it can reload when the tool registers', () async {
      final fake = serve('ws://127.0.0.1:1/a=/ws');
      final app = await apps.attach('ws://127.0.0.1:1/a=/ws');
      expect(registry().byId(app.id)!.canHotReload, isFalse);
      fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await pumpEventQueue();
      expect(registry().byId(app.id)!.canHotReload, isTrue);
    });
  });

  group('the widget picker', () {
    test('arms select mode, waits for the tap, reads the pick', () async {
      final fake = serve(
        'ws://127.0.0.1:1/a=/ws',
        selectedWidget: const {
          'description': 'ElevatedButton',
          'creationLocation': {
            'file': 'file:///C:/app/lib/main.dart',
            'line': 118,
            'column': 22,
          },
          'createdByLocalProject': true,
        },
      );
      final app = await apps.attach('ws://127.0.0.1:1/a=/ws');
      final pick = apps.pickWidget(app.id);
      await pumpEventQueue();
      fake.emitNavigate(line: 118, column: 22);
      final selection = await pick;
      expect(selection.description, 'ElevatedButton');
      expect(selection.location!.line, 118);
      final shows = [
        for (final request in fake.requests)
          if (request.method == 'ext.flutter.inspector.show')
            request.params['enabled'],
      ];
      expect(shows, ['true', 'false']);
    });

    test('no pick in time is refused, not a crash', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      final app = await apps.attach('ws://127.0.0.1:1/a=/ws');
      await expectLater(
        apps.pickWidget(app.id, timeout: const Duration(milliseconds: 20)),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.pickCancelled,
          ),
        ),
      );
    });
  });

  test('the app going away is observed as ended', () async {
    final fake = serve('ws://127.0.0.1:1/a=/ws');
    final app = await apps.attach('ws://127.0.0.1:1/a=/ws');
    await fake.close();
    await pumpEventQueue();
    expect(registry().byId(app.id)!.reachability, AppReachability.ended);
  });

  group('forgetting', () {
    test('drops the row and the stale file', () async {
      final file = writeUriFile('stale.uri', 'ws://127.0.0.1:9/gone=/ws');
      await apps.look();
      await apps.forget(registry().apps.single.id);
      expect(registry().apps, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test('detaching leaves a running app\'s file alone', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      final file = writeUriFile('windows.uri', 'ws://127.0.0.1:1/a=/ws');
      await apps.look();
      await apps.detach(registry().apps.single.id);
      expect(file.existsSync(), isTrue);
      expect(registry().apps.single.reachability, AppReachability.unchecked);
    });
  });

  group('the console', () {
    test('carries what the app said, per app', () async {
      final fake = serve('ws://127.0.0.1:1/a=/ws');
      final app = await apps.attach('ws://127.0.0.1:1/a=/ws');
      fake.emitStdout('flutter: hello\n', at: at);
      await pumpEventQueue();
      expect(
        apps.console(app.id).map((r) => r.message),
        contains('flutter: hello'),
      );
    });

    test(
      'streams as a data source: backlog, then live, then its end',
      () async {
        final fake = serve('ws://127.0.0.1:1/a=/ws');
        final app = await apps.attach('ws://127.0.0.1:1/a=/ws');
        fake.emitStdout('before\n', at: at);
        await pumpEventQueue();
        final feed = FlutterLogsSource(apps).open(app.id);
        expect(
          feed.backlog.map((item) => (item! as Map)['message']),
          contains('before'),
        );
        final live = <Object?>[];
        final done = Completer<void>();
        feed.live.listen(live.add, onDone: done.complete);
        fake.emitStdout('after\n', at: at);
        await pumpEventQueue();
        expect(live.map((item) => (item! as Map)['message']), ['after']);
        expect(
          appLogRecordFromJson(
            (live.single! as Map).cast<String, Object?>(),
          ).message,
          'after',
        );
        await apps.detach(app.id);
        await done.future;
      },
    );

    test('an app not attached is refused as a stream', () {
      expect(
        () => FlutterLogsSource(apps).open('nobody'),
        throwsA(isA<DataRefused>()),
      );
    });
  });
}
