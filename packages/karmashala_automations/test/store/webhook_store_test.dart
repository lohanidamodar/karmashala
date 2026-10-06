import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final testTime = DateTime.utc(2026, 10, 6, 12);
const _hook = '0123456789abcdef0123456789abcdef';

Automation webhookRule({
  String id = 'hook1',
  AutomationWebhook webhook = const AutomationWebhook(
    hookId: _hook,
    modelId: 'opus',
    worktree: true,
    callsPerHour: 12,
  ),
  bool enabled = true,
}) => Automation(
  id: id,
  repositoryId: 'r1',
  name: 'triage-issue',
  schedule: AutomationSchedule.once(testTime),
  agentInstallationId: 'a1',
  prompt: 'Triage {{issue.title}}',
  permissionMode: null,
  enabled: enabled,
  armedAt: testTime,
  webhook: webhook,
);

WebhookCall call({
  String id = 'c1',
  String? automationId = 'hook1',
  int status = 202,
  DateTime? at,
  String? delivery,
}) => WebhookCall(
  id: id,
  automationId: automationId,
  hookId: _hook,
  receivedAt: at ?? testTime,
  ip: '203.0.113.9',
  status: status,
  outcome: status == 202 ? 'accepted' : 'refused',
  bodyHash: 'ab' * 32,
  bodyBytes: 19,
  deliveryId: delivery,
  sessionId: status == 202 ? 's1' : null,
  runId: status == 202 ? 'run1' : null,
);

void main() {
  late AppDatabase db;
  late AutomationDao dao;
  late WebhookCallDao calls;

  setUp(() {
    db = AppDatabase.memory();
    final at = testTime.toIso8601String();
    db
      ..execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('windows', 'windowsNative', 'Windows', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO projects '
        '(id, name, root_environment_id, root_path, created_at) '
        "VALUES ('p1', 'Demo', 'windows', 'C:\\src', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        "VALUES ('r1', 'p1', 'r1', 'windows', 'C:\\src\\r1', ?);",
        [at],
      );
    dao = AutomationDao(db);
    calls = WebhookCallDao(db);
  });
  tearDown(() => db.close());

  group('a webhook automation', () {
    test('round-trips through its row', () {
      dao.insert(webhookRule());
      final read = dao.getById('hook1')!;
      expect(read.webhook, webhookRule().webhook);
      expect(read.isWebhook, isTrue);
      expect(read.isScheduled, isFalse);
      expect(read.isEventDriven, isFalse);
    });

    test('is found by its hook id', () {
      dao.insert(webhookRule());
      expect(dao.byHookId(_hook)?.id, 'hook1');
      expect(dao.byHookId('f' * 32), isNull);
    });

    test('stores no schedule, so an older build reads it as inert', () {
      dao.insert(webhookRule());
      final row = db.query('SELECT * FROM automations;').single;
      expect(row['cron'], isNull);
      expect(row['fires_at'], isNull);
      expect(row['every_seconds'], isNull);
      expect(row['trigger_event'], isNull);
    });

    test('is never among what the scheduler arms', () {
      dao.insert(webhookRule());
      expect(dao.enabled().where((a) => a.isScheduled), isEmpty);
    });

    test('an edit keeps its settings', () {
      dao.insert(webhookRule());
      dao.update(
        webhookRule().copyWith(
          webhook: webhookRule().webhook!.copyWith(requireSignature: false),
        ),
      );
      expect(dao.getById('hook1')!.webhook!.requireSignature, isFalse);
      expect(dao.getById('hook1')!.webhook!.hookId, _hook);
    });

    test('round-trips through the wire', () {
      final json = automationToJson(webhookRule());
      expect(automationFromJson(json).webhook, webhookRule().webhook);
      expect(json.toString(), isNot(contains('secret')));
    });

    test('a plain automation has no webhook on the wire or in its row', () {
      final plain = webhookRule().copyWith(clearWebhook: true);
      expect(automationFromJson(automationToJson(plain)).webhook, isNull);
    });
  });

  group('the call log', () {
    setUp(() => dao.insert(webhookRule()));

    test('keeps every call, newest first, with no body', () {
      calls.insert(call(id: 'c1'));
      calls.insert(
        call(
          id: 'c2',
          status: 401,
          at: testTime.add(const Duration(minutes: 1)),
        ),
      );
      final log = calls.forAutomation('hook1');
      expect([for (final c in log) c.id], ['c2', 'c1']);
      expect(log.last.sessionId, 's1');
      expect(log.last.bodyHash, 'ab' * 32);
      final columns = db.query('SELECT * FROM webhook_calls;').first.keys;
      expect(columns, isNot(contains('body')));
    });

    test('counts accepted calls in a window', () {
      calls.insert(
        call(id: 'c1', at: testTime.subtract(const Duration(hours: 2))),
      );
      calls.insert(call(id: 'c2'));
      calls.insert(call(id: 'c3', status: 429));
      expect(
        calls.acceptedSince(
          'hook1',
          testTime.subtract(const Duration(hours: 1)),
        ),
        1,
      );
    });

    test('remembers a delivery id inside the replay window', () {
      calls.insert(call(id: 'c1', delivery: 'd-1'));
      expect(calls.deliverySeen(_hook, 'd-1', since: testTime), isTrue);
      expect(calls.deliverySeen(_hook, 'd-2', since: testTime), isFalse);
      expect(
        calls.deliverySeen(
          _hook,
          'd-1',
          since: testTime.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('a refused delivery does not burn its id', () {
      calls.insert(call(id: 'c1', status: 401, delivery: 'd-1'));
      expect(calls.deliverySeen(_hook, 'd-1', since: testTime), isFalse);
    });

    test('is pruned to a bound per hook', () {
      for (var i = 0; i < kWebhookCallsKept + 5; i++) {
        calls.insert(
          call(
            id: 'c$i',
            at: testTime.add(Duration(seconds: i)),
          ),
        );
      }
      calls.prune(_hook);
      expect(
        calls.forAutomation('hook1', limit: 1000),
        hasLength(kWebhookCallsKept),
      );
      expect(
        calls.forAutomation('hook1').first.id,
        'c${kWebhookCallsKept + 4}',
      );
    });

    test('a call round-trips through the wire', () {
      final read = webhookCallFromJson(webhookCallToJson(call(delivery: 'd')));
      expect(read.id, 'c1');
      expect(read.deliveryId, 'd');
      expect(read.status, 202);
      expect(read.receivedAt, testTime);
    });

    test('goes with its automation', () {
      calls.insert(call());
      dao.delete('hook1');
      expect(calls.forAutomation('hook1'), isEmpty);
    });
  });
}
