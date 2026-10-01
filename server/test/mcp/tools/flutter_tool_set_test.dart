import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/src/mcp/tools/flutter_tool_set.dart';
import 'package:test/test.dart';

import '../../flutter/flutter_fixture.dart';

void main() {
  late FlutterFixture fixture;

  setUp(() => fixture = FlutterFixture());
  tearDown(() => fixture.close());

  FlutterToolSet tools() => FlutterToolSet(
    apps: fixture.work.apps,
    loop: fixture.work.loop,
    rows: CheckoutRows(fixture.database),
    configurations: fixture.work.configurations,
  );

  Future<Map<String, Object?>> run(Map<String, dynamic> args) async =>
      (await tools().call('flutter_run', args, 's1'))! as Map<String, Object?>;

  String text(Object? answer) =>
      (((answer! as Map)['_mcpContent']! as List).single as Map)['text']!
          as String;

  group('the surface', () {
    test('serves the seven tools, each an object schema', () {
      final names = [for (final s in tools().schemas) s['name']];
      expect(names, [
        'flutter_apps',
        'flutter_attach',
        'flutter_reload',
        'flutter_logs',
        'flutter_pick_widget',
        'flutter_run',
        'flutter_run_config',
      ]);
      for (final schema in tools().schemas) {
        expect((schema['inputSchema']! as Map)['type'], 'object');
      }
    });
  });

  group('flutter_run refuses before it does anything', () {
    test('no action names all six', () {
      expect(
        () => tools().call('flutter_run', {}, null),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            allOf(contains('run, stop, status'), contains('analyze')),
          ),
        ),
      );
    });

    test('an unknown action says so', () {
      expect(
        () => tools().call('flutter_run', {'action': 'launch'}, null),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('no checkoutId points at list_checkouts', () {
      expect(
        () => tools().call('flutter_run', {'action': 'pubGet'}, null),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('list_checkouts'),
          ),
        ),
      );
    });

    test('run with no deviceId names where ids come from', () {
      expect(
        () => tools().call('flutter_run', {
          'action': 'run',
          'checkoutId': 'r1',
        }, null),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('list_devices'),
          ),
        ),
      );
    });

    test('an absolute projectDirectory is refused, not joined', () {
      expect(
        () => tools().call('flutter_run', {
          'action': 'pubGet',
          'checkoutId': 'r1',
          'projectDirectory': '/etc',
        }, null),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('flutter_run', () {
    test('the §17 refusal comes back whole, nothing started', () async {
      fixture.runner.responder = (request) =>
          request.arguments.any((a) => a.contains('command -v'))
          ? const CommandResult(
              exitCode: 0,
              stdout: '/mnt/c/Users/me/flutter/bin/flutter\n',
              stderr: '',
            )
          : const CommandResult(exitCode: 0, stdout: '', stderr: '');
      final answer = await run({'action': 'pubGet', 'checkoutId': 'r1'});
      final preflight = answer['preflight']! as Map;
      expect(preflight['problem'], 'noSdk');
      expect(answer.containsKey('run'), isFalse);
      expect(fixture.pty.started, isEmpty);
    });

    test('an SSH checkout is refused in words', () async {
      final answer = await run({'action': 'pubGet', 'checkoutId': 'rb'});
      expect('${(answer['preflight']! as Map)['reason']}', contains('SSH'));
    });

    test('run names the session and says nothing waits for it', () async {
      final answer = await run({
        'action': 'run',
        'checkoutId': 'r1',
        'deviceId': 'emulator-5554',
        'arguments': ['--profile'],
      });
      expect(answer['preflight'], {'ok': true});
      final paneId = (answer['run']! as Map)['paneId'];
      expect(answer['summary'], contains('$paneId'));
      expect(answer['summary'], contains('Nothing waits'));
      expect(fixture.pty.started.single.argv.last, '--profile');
    });

    test('status with nothing started says so', () async {
      final answer = await run({'action': 'status'});
      expect(answer['runs'], isEmpty);
      expect(answer['summary'], contains('has not started anything'));
    });

    test('a run still going carries its log', () async {
      final started = await run({'action': 'pubGet', 'checkoutId': 'r1'});
      final paneId = (started['run']! as Map)['paneId'];
      fixture.lastProcess.emit(utf8.encode('Resolving dependencies...\r\n'));
      await settle();
      final answer = await run({'action': 'status', 'paneId': paneId});
      final described = answer['run']! as Map;
      expect(described['liveness'], 'running');
      expect(described['log'], contains('Resolving dependencies...'));
    });

    test('a clean finish leaves the log out and says why', () async {
      final started = await run({'action': 'pubGet', 'checkoutId': 'r1'});
      final paneId = (started['run']! as Map)['paneId'];
      fixture.lastProcess.finish(0);
      await settle();
      final answer = await run({'action': 'status', 'paneId': paneId});
      final described = answer['run']! as Map;
      expect(described.containsKey('log'), isFalse);
      expect(described['logNote'], contains('finished cleanly'));
    });

    test('an unknown paneId is answered, not thrown at', () async {
      final answer = await run({'action': 'status', 'paneId': 'nope'});
      expect(answer['summary'], contains('No run in session nope'));
    });

    test('stop with one run needs no paneId; with none says so', () async {
      expect((await run({'action': 'stop'}))['stopped'], isFalse);
      await run({'action': 'pubGet', 'checkoutId': 'r1'});
      final stopped = await run({'action': 'stop'});
      expect(stopped['stopped'], isTrue);
      expect(stopped['summary'], contains('stopped rather than detached'));
    });

    test('stop with two running refuses to guess', () async {
      await run({'action': 'pubGet', 'checkoutId': 'r1'});
      await run({'action': 'analyze', 'checkoutId': 'r1'});
      expect((await run({'action': 'stop'}))['stopped'], isFalse);
    });
  });

  group('the app tools', () {
    const wsUri = 'ws://127.0.0.1:53119/tok=/ws';

    test('flutter_apps with nothing says how one becomes visible', () async {
      final answer =
          await tools().call('flutter_apps', {}, null) as Map<String, Object?>;
      expect(answer['apps'], isEmpty);
      expect(answer['howToMakeOneVisible'], contains('found on their own'));
    });

    test('flutter_attach takes the printed address', () async {
      fixture.reachable[wsUri] = FakeVmService();
      final answer =
          await tools().call('flutter_attach', {
                'vmServiceUri': 'http://127.0.0.1:53119/tok=/',
              }, null)
              as Map<String, Object?>;
      expect((answer['attached']! as Map)['reachability'], 'attached');
    });

    test('flutter_attach with no address is refused with the remedy', () {
      expect(
        () => tools().call('flutter_attach', {}, null),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('flutter_reload says what it proved and what not', () async {
      final fake = fixture.reachable[wsUri] = FakeVmService();
      await fixture.work.apps.attach(wsUri);
      fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await settle();
      final answer =
          await tools().call('flutter_reload', {}, null)
              as Map<String, Object?>;
      expect(answer['kind'], 'hotReload');
      expect(answer['note'], contains('flutter_logs'));
      expect(fake.methods, contains('s1.reloadSources'));
    });

    test('flutter_logs is prose, and errorsOnly leaves chatter out', () async {
      final fake = fixture.reachable[wsUri] = FakeVmService();
      await fixture.work.apps.attach(wsUri);
      fake
        ..emitStdout(
          'chatter\n',
          at: fixtureNow.add(const Duration(seconds: 1)),
        )
        ..emitStdout(
          'boom\n',
          stderr: true,
          at: fixtureNow.add(const Duration(seconds: 1)),
        );
      await settle();
      final all = text(await tools().call('flutter_logs', {}, null));
      expect(all, contains('[out] chatter'));
      expect(all, contains('[err] boom'));
      final errors = text(
        await tools().call('flutter_logs', {'errorsOnly': true}, null),
      );
      expect(errors, isNot(contains('chatter')));
    });

    test('flutter_pick_widget introduces the developer\'s choice', () async {
      final fake = fixture.reachable[wsUri] = FakeVmService(
        selectedWidget: const {'description': 'Text'},
      );
      await fixture.work.apps.attach(wsUri);
      final pick = tools().call('flutter_pick_widget', {}, null)!;
      await settle();
      fake.emitNavigate();
      final answer = text(await pick);
      expect(answer, contains('The developer pointed at this widget'));
      expect(answer, contains('Widget: Text'));
    });
  });
}
