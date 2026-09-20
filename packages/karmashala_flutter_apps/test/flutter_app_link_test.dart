import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

import './fake_vm_service.dart';

void main() {
  final uri = Uri.parse('ws://127.0.0.1:53119/tok=/ws');

  Future<(FlutterAppLink, FakeVmService)> build({
    Set<String> refuseStreams = const <String>{},
    Map<String, Object?>? selectedWidget,
    DateTime? now,
  }) async {
    final fake = FakeVmService(
      refuseStreams: refuseStreams,
      selectedWidget: selectedWidget,
    );
    final link = await FlutterAppLink.attach(
      uri,
      connect: (_) async => fake.client,
      now: () => now ?? DateTime.utc(2026, 9, 8, 12),
    );
    return (link, fake);
  }

  group('attaching', () {
    test('subscribes the streams the console and the picker need', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      final listened = <String>[
        for (final request in fake.requests)
          if (request.method == 'streamListen')
            request.params['streamId'] as String,
      ];
      expect(
        listened,
        containsAll(<String>[
          'Stdout',
          'Stderr',
          'Logging',
          'Extension',
          'Service',
          'ToolEvent',
        ]),
      );
      expect(link.isolateId, 'isolates/1');
    });

    test(
      'subscribes before asking anything, so no history is missed',
      () async {
        final (link, fake) = await build();
        addTearDown(link.dispose);
        expect(
          fake.methods.indexOf('getVM'),
          greaterThan(fake.methods.indexOf('streamListen')),
        );
      },
    );

    test('a VM service without ToolEvent is reported, not assumed', () async {
      final (link, _) = await build(refuseStreams: const {'ToolEvent'});
      addTearDown(link.dispose);
      expect(link.toolEventStreamListenable, isFalse);
    });

    test('a refused connection becomes a named failure', () async {
      await expectLater(
        FlutterAppLink.attach(
          uri,
          connect: (_) async => throw const SocketFailure(),
        ),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.connectFailed,
          ),
        ),
      );
    });
  });

  group('the console', () {
    test('decodes stdout and keeps stderr apart from it', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      fake.emitStdout('flutter: hello\n');
      fake.emitStdout('boom\n', stderr: true);
      await pumpEventQueue();
      expect(
        link.console.map((r) => (r.source, r.message)),
        containsAll(<Object>[
          (AppLogSource.stdout, 'flutter: hello'),
          (AppLogSource.stderr, 'boom'),
        ]),
      );
    });

    test(
      'carries a dart:developer record with its channel and level',
      () async {
        final (link, fake) = await build();
        addTearDown(link.dispose);
        fake.emitDeveloperLog(
          'the thing',
          loggerName: 'probe.channel',
          level: 900,
        );
        await pumpEventQueue();
        final record = link.console.firstWhere(
          (r) => r.source == AppLogSource.developerLog,
        );
        expect(record.message, 'the thing');
        expect(record.loggerName, 'probe.channel');
        expect(record.level, 900);
      },
    );

    test('keeps Flutter.Error and drops Flutter.Frame', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      fake.emitFrame();
      fake.emitFrame();
      fake.emitFlutterError(flutterErrorTree());
      await pumpEventQueue();
      expect(
        link.console.where((r) => r.source == AppLogSource.flutterError),
        hasLength(1),
      );
      expect(link.console.map((r) => r.message), isNot(contains('elapsed')));
    });

    test('marks replayed history rather than presenting it as now', () async {
      final attachedAt = DateTime.utc(2026, 9, 8, 12);
      final (link, fake) = await build(now: attachedAt);
      addTearDown(link.dispose);
      fake.emitStdout(
        'startup',
        at: attachedAt.subtract(const Duration(minutes: 5)),
      );
      fake.emitStdout(
        'right now',
        at: attachedAt.add(const Duration(seconds: 1)),
      );
      await pumpEventQueue();
      final byMessage = <String, bool>{
        for (final record in link.console) record.message: record.beforeAttach,
      };
      expect(byMessage['startup'], isTrue);
      expect(byMessage['right now'], isFalse);
    });

    test(
      'notes attaching, because the console explains its own gaps',
      () async {
        final (link, _) = await build();
        addTearDown(link.dispose);
        expect(
          link.console.where((r) => r.source == AppLogSource.lifecycle),
          isNotEmpty,
        );
      },
    );
  });

  group('hot reload', () {
    test(
      'uses the method name the tool registered, not a guessed prefix',
      () async {
        final (link, fake) = await build();
        addTearDown(link.dispose);
        // Measured 2026-09-08: DDS numbers the registering client per
        // connection, so ours sees `s1.`, not the `s0.` the tool sees.
        fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
        await pumpEventQueue();
        expect(link.reloadMethod, 's1.reloadSources');

        await link.hotReload();
        expect(fake.methods, contains('s1.reloadSources'));
        expect(fake.paramsFor('s1.reloadSources'), <String, Object?>{
          'isolateId': 'isolates/1',
          'force': false,
          'pause': false,
        });
      },
    );

    test('refuses when nothing is there to recompile', () async {
      final (link, _) = await build();
      addTearDown(link.dispose);
      await expectLater(
        link.hotReload(),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.notToolDriven,
          ),
        ),
      );
    });

    test('a tool that detaches takes hot reload with it', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await pumpEventQueue();
      fake.emitServiceUnregistered('reloadSources');
      await pumpEventQueue();
      expect(link.reloadMethod, isNull);
      expect(
        link.console.map((r) => r.message),
        contains(
          'The Flutter tool detached; hot reload is no longer available.',
        ),
      );
    });

    test('hot restart takes only pause', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      fake.emitServiceRegistered('hotRestart', 's1.hotRestart');
      await pumpEventQueue();
      await link.hotRestart();
      expect(fake.paramsFor('s1.hotRestart'), <String, Object?>{
        'pause': false,
      });
    });
  });

  group('the inspector', () {
    test('asks whether this build carries widget locations', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      expect(await link.widgetLocationSupport(), WidgetLocationSupport.tracked);

      fake.handlers['ext.flutter.inspector.isWidgetCreationTracked'] = (_) =>
          <String, Object?>{'type': '_extensionType', 'result': false};
      expect(await link.widgetLocationSupport(), WidgetLocationSupport.absent);
    });

    test(
      'a build with no inspector at all reads as unknown, not absent',
      () async {
        final (link, fake) = await build();
        addTearDown(link.dispose);
        fake.handlers['ext.flutter.inspector.isWidgetCreationTracked'] = (_) =>
            const FakeRpcError.methodNotFound();
        expect(
          await link.widgetLocationSupport(),
          WidgetLocationSupport.unknown,
        );
      },
    );

    test(
      'select mode is turned on with the string the framework compares',
      () async {
        final (link, fake) = await build();
        addTearDown(link.dispose);
        await link.setWidgetSelectMode(enabled: true);
        expect(
          fake.paramsFor('ext.flutter.inspector.show')!['enabled'],
          'true',
          reason: '_registerBoolServiceExtension compares against the string',
        );
      },
    );

    test('a missing extension is named as a build problem', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      fake.handlers['ext.flutter.inspector.show'] = (_) =>
          const FakeRpcError.methodNotFound();
      await expectLater(
        link.setWidgetSelectMode(enabled: true),
        throwsA(
          isA<FlutterAppException>().having(
            (e) => e.failure,
            'failure',
            FlutterAppFailure.extensionMissing,
          ),
        ),
      );
    });

    test('reads the selection and disposes the group it created', () async {
      final (link, fake) = await build(
        selectedWidget: const <String, Object?>{
          'description': 'Text',
          'creationLocation': <String, Object?>{
            'file': 'file:///C:/app/lib/main.dart',
            'line': 107,
            'column': 19,
          },
          'createdByLocalProject': true,
        },
      );
      addTearDown(link.dispose);
      final selection = await link.selectedWidget();
      expect(selection!.description, 'Text');
      expect(selection.location!.line, 107);
      expect(fake.methods, contains('ext.flutter.inspector.disposeGroup'));
    });

    test('pushes the framework selection as an event', () async {
      final (link, fake) = await build();
      addTearDown(link.dispose);
      final seen = link.navigations.first;
      fake.emitNavigate(line: 118, column: 22);
      final location = await seen;
      expect(location.line, 118);
      expect(location.column, 22);
    });
  });

  test('the app going away arrives as an event, not as a probe', () async {
    final (link, fake) = await build();
    await fake.close();
    await link.done;
    expect(
      link.console.map((r) => r.message),
      contains('The app closed its VM service connection.'),
    );
  });
}

class SocketFailure implements Exception {
  const SocketFailure();
  @override
  String toString() => 'Connection refused';
}
