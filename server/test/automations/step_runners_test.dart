import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/step_runners.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The two steps that reach outside a run: a command, which takes values
/// only as its environment, and a webhook, which will not call into the
/// owner's network unless they tick it.
void main() {
  group('private addresses', () {
    test('loopback, private, link-local and their IPv6 forms are private', () {
      for (final address in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '::1',
        'fe80::1',
        'fd00::1',
        '::ffff:10.0.0.1',
      ]) {
        expect(
          isPrivateAddress(InternetAddress(address)),
          isTrue,
          reason: address,
        );
      }
    });

    test('public addresses are not', () {
      for (final address in ['8.8.8.8', '172.32.0.1', '2606:4700::1111']) {
        expect(
          isPrivateAddress(InternetAddress(address)),
          isFalse,
          reason: address,
        );
      }
    });
  });

  group('the webhook step', () {
    late HttpServer server;
    late List<HttpRequest> received;
    late List<String> bodies;

    setUp(() async {
      received = [];
      bodies = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        received.add(request);
        bodies.add(await utf8.decodeStream(request));
        request.response
          ..statusCode = 202
          ..write('{"queued": true}');
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    Uri url() => Uri.parse('http://localhost:${server.port}/hook');

    // localhost resolves to loopback, whatever the machine's resolver says.
    ServerStepWebhooks poster() =>
        ServerStepWebhooks(lookup: (_) async => [InternetAddress.loopbackIPv4]);

    test('an address on your network is refused without the tick', () async {
      await expectLater(
        poster().post(
          url(),
          body: '{}',
          idempotencyKey: 'run1-webhook',
          allowPrivate: false,
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Allow addresses on my network'),
          ),
        ),
      );
      expect(received, isEmpty);
    });

    test('a name that resolves to a private address is refused too', () async {
      final refusing = ServerStepWebhooks(
        lookup: (_) async => [InternetAddress('10.0.0.7')],
      );
      await expectLater(
        refusing.post(
          Uri.parse('https://innocent.example.com/x'),
          body: '{}',
          idempotencyKey: 'k',
          allowPrivate: false,
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('with the tick it posts JSON with the Idempotency-Key', () async {
      final answer = await poster().post(
        url(),
        body: '{"a": "b"}',
        idempotencyKey: 'run1-webhook',
        allowPrivate: true,
        timeout: const Duration(seconds: 5),
      );
      expect(answer.status, 202);
      expect(answer.body, '{"queued": true}');
      final request = received.single;
      expect(request.method, 'POST');
      expect(request.headers.value('idempotency-key'), 'run1-webhook');
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(bodies.single, '{"a": "b"}');
    });

    test('a URL that does not answer in time fails the step', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      final held = <Socket>[];
      silent.listen(held.add);
      addTearDown(() {
        for (final s in held) {
          s.destroy();
        }
      });
      await expectLater(
        poster().post(
          Uri.parse('http://localhost:${silent.port}/'),
          body: '{}',
          idempotencyKey: 'k',
          allowPrivate: true,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('did not answer'),
          ),
        ),
      );
    });
  });

  group('the command step', () {
    late AppDatabase db;
    late Directory checkout;
    late ServerStepCommands commands;
    final windows = Platform.isWindows;

    setUp(() {
      checkout = Directory.systemTemp.createTempSync('command-step-');
      db = AppDatabase.memory();
      db.execute('PRAGMA foreign_keys = OFF;');
      final at = DateTime.utc(2026, 10, 7).toIso8601String();
      db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('local', ?, 'this machine', ?);",
        [windows ? 'windowsNative' : 'localPosix', at],
      );
      db.execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, '
        "path, created_at) VALUES ('r1', 'p1', 'shop', 'local', ?, ?);",
        [checkout.path, at],
      );
      commands = ServerStepCommands(
        facts: DaemonCheckoutFacts(CheckoutRows(db), windows: windows),
        sessionOf: (_) => null,
      );
    });
    tearDown(() async {
      db.close();
      // A killed process lets go of its working folder a moment later.
      for (var attempt = 0; ; attempt++) {
        try {
          checkout.deleteSync(recursive: true);
          return;
        } on FileSystemException {
          if (attempt == 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    });

    final automation = Automation(
      id: 'a1',
      repositoryId: 'r1',
      name: 'Push',
      schedule: AutomationSchedule.once(DateTime.utc(2026)),
      agentInstallationId: '',
      prompt: '',
      permissionMode: null,
      enabled: true,
      armedAt: DateTime.utc(2026),
    );
    final run = AutomationRun(
      id: 'run1',
      automationId: 'a1',
      scheduledFor: DateTime.utc(2026),
      firedAt: DateTime.utc(2026),
      state: AutomationRunState.finished,
      reason: '',
    );

    test('a hostile branch name is read as a value and never runs', () async {
      const branch =
          r'x"; touch pwned1; echo "$(touch pwned2)` & type nul > pwned3 '
          r"'; New-Item pwned4; $(New-Item pwned5)";
      final result = await commands.run(
        automation,
        run,
        command: windows
            ? r'Write-Output $env:KARMASHALA_GITHUB_PR_BRANCH'
            : r'printf "%s\n" "$KARMASHALA_GITHUB_PR_BRANCH"',
        environment: stepEnvironment({'github.pr.branch': branch}),
        timeout: const Duration(minutes: 1),
      );
      expect(result.exitCode, 0);
      expect(result.output.trim(), branch);
      expect(
        checkout.listSync().map((e) => e.path),
        isEmpty,
        reason: 'nothing the value said was run',
      );
    });

    test('a command past its time limit is stopped', () async {
      final result = await commands.run(
        automation,
        run,
        command: windows ? 'Start-Sleep -Seconds 30' : 'sleep 30',
        environment: const {},
        timeout: const Duration(seconds: 2),
      );
      expect(result.timedOut, isTrue);
      expect(result.exitCode, isNull);
    });

    test('its exit code and output come back', () async {
      final result = await commands.run(
        automation,
        run,
        command: windows ? 'Write-Output hi; exit 3' : 'echo hi; exit 3',
        environment: const {},
        timeout: const Duration(minutes: 1),
      );
      expect(result.exitCode, 3);
      expect(result.output.trim(), 'hi');
    });
  });
}
