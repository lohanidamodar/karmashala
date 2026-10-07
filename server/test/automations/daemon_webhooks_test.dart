import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/automations/webhooks/daemon_webhooks.dart';
import 'package:karmashala_host/src/automations/webhooks/server_hook_vault.dart';
import 'package:karmashala_mcp/access.dart' show HandshakePermissions;
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/remote.dart' show Backoff;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

class _Permissions extends HandshakePermissions {
  const _Permissions();
  @override
  Future<bool> restrictDirectory(Directory dir, {Object? logger}) async => true;
  @override
  Future<bool> restrictFile(File file, {Object? logger}) async => true;
}

Future<void> _until(bool Function() done, {String what = 'it'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory temp;
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late DaemonWebhooks webhooks;
  late RelayServer relay;
  late List<Automation> launched;
  late List<DataChange> told;
  Uri? relayUrl;
  final now = DateTime.utc(2026, 10, 6, 12);

  Automation hook({
    String id = 'auto-hook',
    String hookId = '',
    bool enabled = true,
    String prompt = 'Triage {{issue.title}}',
  }) => Automation(
    id: id,
    repositoryId: 'r1',
    name: 'triage-issue',
    schedule: AutomationSchedule.once(now),
    agentInstallationId: 'a1',
    prompt: prompt,
    permissionMode: null,
    enabled: enabled,
    armedAt: now,
    worktree: true,
    webhook: AutomationWebhook(hookId: hookId),
  );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('daemon_webhooks_');
    db = AppDatabase.memory();
    const at = '2026-01-01T00:00:00.000Z';
    db
      ..execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('windows', 'windowsNative', 'Windows', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO projects (id, name, root_environment_id, root_path, '
        "created_at) VALUES ('p1', 'Demo', 'windows', 'C:\\src', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, '
        "path, created_at) VALUES ('r1', 'p1', 'r1', 'windows', "
        "'C:\\src\\r1', ?);",
        [at],
      );
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUrl = Uri.parse('ws://127.0.0.1:${relay.port}');
    launched = [];
    told = [];
    service = DataService(db, clock: () => now);
    webhooks = DaemonWebhooks(
      database: db,
      vault: ServerHookVault(
        dataDirectory: temp.path,
        permissions: const _Permissions(),
      ),
      launch: (automation, note) async {
        launched.add(automation);
        final run = AutomationRun(
          id: 'run-${launched.length}',
          automationId: automation.id,
          scheduledFor: now,
          firedAt: now,
          state: AutomationRunState.running,
          reason: note,
          sessionId: 'session-${launched.length}',
        );
        AutomationDao(db).insertRun(run);
        return run;
      },
      busy: (_) => false,
      relay: () => relayUrl,
      tell: told.addAll,
      clock: () => DateTime.now().toUtc(),
      backoff: () => Backoff(
        initial: const Duration(milliseconds: 20),
        maximum: const Duration(milliseconds: 100),
      ),
    );
    service
      ..webhooksWork = webhooks
      ..automationsWritten = webhooks.reconcile;
    app = service.open((_) {});
  });
  tearDown(() async {
    await webhooks.close();
    await relay.close();
    db.close();
    temp.deleteSync(recursive: true);
  });

  Automation save(Automation automation) =>
      app.handle(AutomationSave(automation)).value;

  Future<(int, Map<String, Object?>)> post(
    String url,
    List<int> body, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      headers.forEach(request.headers.set);
      request.add(body);
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return (response.statusCode, jsonDecode(text) as Map<String, Object?>);
    } finally {
      client.close(force: true);
    }
  }

  group('saving a webhook', () {
    test('the server chooses its hook id, never the client', () {
      final stored = save(hook(hookId: 'a' * 32));
      expect(stored.webhook!.hookId, isNot('a' * 32));
      expect(
        RegExp(r'^[0-9a-f]{32}$').hasMatch(stored.webhook!.hookId),
        isTrue,
      );
    });

    test('an edit keeps the hook id', () {
      final first = save(hook());
      final edited = save(hook(prompt: 'Look at {{issue.title}}'));
      expect(edited.webhook!.hookId, first.webhook!.hookId);
    });

    test('a client that knows no webhooks cannot drop one by saving', () {
      final first = save(hook());
      final old = first.copyWith(clearWebhook: true, name: 'renamed');
      final stored = save(old);
      expect(stored.webhook, first.webhook);
      expect(stored.name, 'renamed');
    });

    test('a malformed template is refused', () {
      expect(
        () => save(hook(prompt: 'Look at {{a b}}')),
        throwsA(isA<DataRefused>()),
      );
    });
  });

  test('rotate answers a secret and the URL once; status never does', () async {
    final stored = save(hook());
    final issued = await app.handleLater(const WebhookRotate('auto-hook'));
    final secret = issued.value.secret;
    expect(secret, startsWith('whsec_'));
    final listenId = hooksListenIdOf(
      (await ServerHookVault(
        dataDirectory: temp.path,
        permissions: const _Permissions(),
      ).listenKey()),
    );
    expect(
      issued.value.url,
      'http://127.0.0.1:${relay.port}/h/$listenId/${stored.webhook!.hookId}',
    );
    final status = await app.handleLater(const WebhookStatusRead('auto-hook'));
    expect(jsonEncode(status.value.toJson()), isNot(contains(secret)));
    expect(status.value.url, issued.value.url);
  });

  test('a call through the relay starts one session; rotating the secret '
      'refuses the old one at once', () async {
    save(hook());
    final first = (await app.handleLater(
      const WebhookRotate('auto-hook'),
    )).value;
    await _until(() => webhooks.listening, what: 'the listener');
    final body = utf8.encode('{"issue":{"title":"Crash"}}');
    final (status, answer) = await post(
      first.url!,
      body,
      headers: {'x-hub-signature-256': webhookSignatureFor(first.secret, body)},
    );
    expect(status, 202);
    expect(answer, {'session': 'session-1', 'run': 'run-1'});
    expect(launched, hasLength(1));
    expect(told.whereType<WebhookCallRecorded>(), hasLength(1));

    final second = (await app.handleLater(
      const WebhookRotate('auto-hook'),
    )).value;
    final (old, _) = await post(
      first.url!,
      body,
      headers: {'x-hub-signature-256': webhookSignatureFor(first.secret, body)},
    );
    expect(old, 401);
    final (fresh, _) = await post(
      second.url!,
      body,
      headers: {
        'x-hub-signature-256': webhookSignatureFor(second.secret, body),
      },
    );
    expect(fresh, 202);
    expect(launched, hasLength(2));

    final log = (await app.handleLater(
      const WebhookStatusRead('auto-hook'),
    )).value.calls;
    expect([for (final c in log) c.status], [202, 401, 202]);
  });

  test(
    'the listener runs while a webhook is enabled, and stops after',
    () async {
      save(hook());
      await _until(() => relay.hookListenerCount == 1, what: 'the listener');
      app.handle(const AutomationSetEnabled('auto-hook', enabled: false));
      await _until(() => relay.hookListenerCount == 0, what: 'the stop');
      app.handle(const AutomationSetEnabled('auto-hook', enabled: true));
      await _until(() => relay.hookListenerCount == 1, what: 'the restart');
      relayUrl = null;
      webhooks.reconcile();
      await _until(() => relay.hookListenerCount == 0, what: 'no relay');
    },
  );

  test('a deleted webhook forgets its secret', () async {
    final stored = save(hook());
    await app.handleLater(const WebhookRotate('auto-hook'));
    app.handle(const AutomationDelete('auto-hook'));
    webhooks.reconcile();
    await _until(
      () =>
          ServerHookVault(
            dataDirectory: temp.path,
            permissions: const _Permissions(),
          ).secretOf(stored.webhook!.hookId) ==
          null,
      what: 'the secret to go',
    );
  });

  test('a phone may read a webhook but not mint its secret', () async {
    save(hook());
    final phone = service.open((_) {}, phone: true);
    await expectLater(
      phone.handleLater(const WebhookRotate('auto-hook')),
      throwsA(isA<DataRefused>()),
    );
    expect(
      (await phone.handleLater(
        const WebhookStatusRead('auto-hook'),
      )).value.calls,
      isEmpty,
    );
  });
}
