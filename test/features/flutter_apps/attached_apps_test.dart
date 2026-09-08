import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/flutter_apps/application/attached_apps.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala/src/features/flutter_apps/data/vm_service_uri_directory.dart';
import 'package:karmashala/src/features/flutter_apps/domain/attached_app.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_app_failure.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_app_registry.dart';

import '../../support/fakes.dart';
import 'fake_vm_service.dart';

void main() {
  late Directory temp;
  late Map<String, FakeVmService> reachable;
  late ProviderContainer container;

  final at = DateTime.utc(2026, 9, 8, 12);

  /// `flutter run --vmservice-out-file` writes exactly this, and nothing else.
  File writeUriFile(String name, String wsUri) =>
      File('${temp.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync(wsUri);

  FakeVmService serve(String wsUri, {Map<String, Object?>? selectedWidget}) {
    final fake = FakeVmService(selectedWidget: selectedWidget);
    reachable[wsUri] = fake;
    return fake;
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('karmashala-vmservice-test');
    reachable = <String, FakeVmService>{};
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(at)),
        flutterAppDiscoveryDirectoryProvider.overrideWith(
          (ref) async => VmServiceUriDirectory(temp),
        ),
        vmServiceConnectorProvider.overrideWithValue((uri) async {
          final fake = reachable[uri.toString()];
          if (fake == null) throw const _Refused();
          return fake.client;
        }),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  AttachedApps apps() => container.read(attachedAppsProvider.notifier);
  FlutterAppRegistry registry() => container.read(attachedAppsProvider);

  group('discovery', () {
    test('nothing has been looked for until something looks', () {
      expect(registry().hasLooked, isFalse);
      expect(
        describeRegistry(registry()),
        'We have not looked for a running Flutter app yet.',
      );
    });

    test('finds and attaches to what flutter run left behind', () async {
      const uri = 'ws://127.0.0.1:53119/tok=/ws';
      serve(uri);
      writeUriFile('windows.uri', uri);

      await apps().look();

      expect(registry().apps, hasLength(1));
      final app = registry().apps.single;
      expect(app.reachability, AppReachability.attached);
      expect(app.discovery, AppDiscovery.uriFile);
      expect(app.label, 'windows');
      expect(app.isolateId, 'isolates/1');
      expect(describeRegistry(registry()), '1 Flutter app attached.');
    });

    test('holds several apps at once, each with its own connection', () async {
      const desktop = 'ws://127.0.0.1:1/a=/ws';
      const phone = 'ws://127.0.0.1:2/b=/ws';
      serve(desktop);
      serve(phone);
      writeUriFile('windows.uri', desktop);
      writeUriFile('pixel.uri', phone);

      await apps().look();

      expect(registry().attached, hasLength(2));
      expect(
        registry().apps.map((app) => app.label).toSet(),
        {'windows', 'pixel'},
      );
      expect(describeRegistry(registry()), '2 Flutter apps attached.');
    });

    test('a file nothing answers on is on record, not deleted', () async {
      writeUriFile('stale.uri', 'ws://127.0.0.1:9/gone=/ws');

      await apps().look();

      final app = registry().apps.single;
      expect(app.reachability, AppReachability.unreachable);
      expect(app.detail, contains('Nothing answered on that address'));
      expect(
        describeRegistry(registry()),
        '1 address is on record and nothing answers on it.',
      );
      expect(File('${temp.path}${Platform.pathSeparator}stale.uri').existsSync(), isTrue);
    });

    test('a file that is not an address is ignored, not reported', () async {
      writeUriFile('notes.txt', 'remember to buy milk');
      await apps().look();
      expect(registry().apps, isEmpty);
      expect(
        describeRegistry(registry()),
        'No Flutter app is running that we can see.',
      );
    });

    test('an app already attached is not re-handshaked by a second look', () async {
      const uri = 'ws://127.0.0.1:53119/tok=/ws';
      final fake = serve(uri);
      writeUriFile('windows.uri', uri);
      await apps().look();
      final handshakes = fake.methods.where((m) => m == 'getVM').length;
      await apps().look();
      expect(fake.methods.where((m) => m == 'getVM').length, handshakes);
    });

    test('a removed file drops its row', () async {
      const uri = 'ws://127.0.0.1:9/gone=/ws';
      final file = writeUriFile('stale.uri', uri);
      await apps().look();
      expect(registry().apps, hasLength(1));
      file.deleteSync();
      await apps().look();
      expect(registry().apps, isEmpty);
    });

    test('the remedy names the real directory', () async {
      await apps().look();
      expect(apps().attachHint, contains(temp.path));
      expect(apps().attachHint, contains('--vmservice-out-file'));
    });
  });

  group('attaching by hand', () {
    test('takes the address flutter run prints', () async {
      serve('ws://127.0.0.1:53119/tok=/ws');
      final app = await apps().attach('http://127.0.0.1:53119/tok=/');
      expect(app.reachability, AppReachability.attached);
      expect(app.discovery, AppDiscovery.byHand);
    });

    test('is idempotent, so a retried call cannot open two connections', () async {
      const uri = 'ws://127.0.0.1:53119/tok=/ws';
      final fake = serve(uri);
      await apps().attach(uri);
      await apps().attach(uri);
      expect(fake.methods.where((m) => m == 'getVM'), hasLength(1));
      expect(registry().apps, hasLength(1));
    });

    test('refuses something that is not an address', () async {
      await expectLater(
        apps().attach('the app on my phone'),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.badUri,
          ),
        ),
      );
    });

    test('says nothing answered rather than pretending it attached', () async {
      await expectLater(
        apps().attach('ws://127.0.0.1:9/gone=/ws'),
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
      await apps().attach('ws://127.0.0.1:1/a=/ws');
      expect(apps().requireApp(null).uri.port, 1);
    });

    test('two attached apps are refused by name, not guessed', () async {
      serve('ws://127.0.0.1:1/a=/ws');
      serve('ws://127.0.0.1:2/b=/ws');
      await apps().attach('ws://127.0.0.1:1/a=/ws');
      await apps().attach('ws://127.0.0.1:2/b=/ws');
      expect(
        () => apps().requireApp(null),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.ambiguousApp,
          ),
        ),
      );
    });

    test('nothing attached carries the remedy with the refusal', () async {
      await apps().look();
      expect(
        () => apps().requireApp(null),
        throwsA(
          isA<FlutterAppException>()
              .having((e) => e.failure, 'failure', FlutterAppFailure.noAppAttached)
              .having((e) => e.message, 'message', contains('--vmservice-out-file')),
        ),
      );
    });

    test('an id from a run that has ended is not silently swapped', () async {
      expect(
        () => apps().requireApp('127.0.0.1:1/old='),
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
      const one = 'ws://127.0.0.1:1/a=/ws';
      const two = 'ws://127.0.0.1:2/b=/ws';
      final first = serve(one);
      final second = serve(two);
      final a = await apps().attach(one);
      await apps().attach(two);
      first.emitServiceRegistered('reloadSources', 's1.reloadSources');
      second.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await pumpEventQueue();

      await apps().hotReload(a.id);

      expect(first.methods, contains('s1.reloadSources'));
      expect(second.methods, isNot(contains('s1.reloadSources')));
    });

    test('the row learns it can reload when the tool registers', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      final app = await apps().attach(uri);
      expect(registry().byId(app.id)!.canHotReload, isFalse);
      fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await pumpEventQueue();
      expect(registry().byId(app.id)!.canHotReload, isTrue);
      expect(registry().byId(app.id)!.reloadMethod, 's1.reloadSources');
    });
  });

  group('the widget picker', () {
    test('arms select mode, waits for the tap and reads the selection', () async {
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
      final app = await apps().attach(uri);

      final pick = apps().pickWidget(app.id);
      await pumpEventQueue();
      expect(
        fake.paramsFor('ext.flutter.inspector.show')!['enabled'],
        'true',
      );
      fake.emitNavigate(line: 118, column: 22);
      final selection = await pick;

      expect(selection.description, 'ElevatedButton');
      expect(selection.location!.line, 118);
      // And it leaves the app as it found it.
      final shows = <Object?>[
        for (final request in fake.requests)
          if (request.method == 'ext.flutter.inspector.show')
            request.params['enabled'],
      ];
      expect(shows, ['true', 'false']);
    });

    test('does no hit-testing of its own', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri, selectedWidget: const {'description': 'Text'});
      final app = await apps().attach(uri);
      final pick = apps().pickWidget(app.id);
      await pumpEventQueue();
      fake.emitNavigate();
      await pick;
      // The framework hit-tests the tap; nothing here reads coordinates or a
      // widget tree to work out what was under the finger.
      expect(
        fake.methods,
        isNot(contains('ext.flutter.inspector.getRootWidgetSummaryTree')),
      );
    });

    test('leaving select mode without a pick is not a crash', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      serve(uri);
      final app = await apps().attach(uri);
      await expectLater(
        apps().pickWidget(app.id, timeout: const Duration(milliseconds: 20)),
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

  group('the app going away', () {
    test('is observed, and says so rather than reading as never-there', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      final app = await apps().attach(uri);
      await fake.close();
      await pumpEventQueue();
      expect(registry().byId(app.id)!.reachability, AppReachability.ended);
      expect(registry().byId(app.id)!.canHotReload, isFalse);
    });
  });

  group('forgetting', () {
    test('drops the row and the stale file, once the user asks', () async {
      final file = writeUriFile('stale.uri', 'ws://127.0.0.1:9/gone=/ws');
      await apps().look();
      await apps().forget(registry().apps.single.id);
      expect(registry().apps, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test('detaching from a running app leaves its file alone', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      serve(uri);
      final file = writeUriFile('windows.uri', uri);
      await apps().look();
      await apps().detach(registry().apps.single.id);
      expect(file.existsSync(), isTrue);
      expect(registry().apps.single.reachability, AppReachability.unchecked);
    });
  });

  group('the console', () {
    test('is per app, and carries what the app said before we attached', () async {
      const uri = 'ws://127.0.0.1:1/a=/ws';
      final fake = serve(uri);
      final app = await apps().attach(uri);
      fake.emitStdout('flutter: hello\n', at: at.add(const Duration(seconds: 1)));
      await pumpEventQueue();
      final lines = apps().console(app.id).map((r) => r.message);
      expect(lines, contains('flutter: hello'));
    });
  });
}

class _Refused implements Exception {
  const _Refused();
  @override
  String toString() => 'Connection refused';
}
