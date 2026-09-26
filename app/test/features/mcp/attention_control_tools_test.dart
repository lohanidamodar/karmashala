import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

/// The inbox, over the endpoint: what makes an agent able to notice that
/// another agent is stuck. Until now the only consumer of that state was a
/// human reading a badge. (Notes are the server's now:
/// `server/test/mcp/tools/notes_todos_tool_set_test.dart`.)
void main() {
  late Directory tmp;
  late TestMachine db;
  late ProviderContainer container;
  late LauncherControlServer server;

  const key = AgentSessionKey('claudeCode', 'cli-1');
  const watched = WatchedSession(
    key: key,
    label: 'Fix login',
    openId: 's1',
    imported: false,
  );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_attention_tools_');
    db = TestMachine();
    final fake = FakeDataServer(
      clock: () => testTime,
      repositoryOfSession: {'s1': 'r1'},
      projectOfRepository: {'r1': 'p1'},
    )..runsOn(db);
    fake.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    fake.projectRows.insert(project());
    fake.repositoryRows.insert(repository());
    fake.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(session(id: 's1', title: 'Fix login'));

    final data = await fake.override();
    container = ProviderContainer(
      overrides: [data, clockProvider.overrideWithValue(FixedClock(testTime))],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<({bool isError, String text, Object? structured})> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
    String? asSession,
  ]) async {
    final json =
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;
    final credential = asSession == null
        ? json['mcpToken']! as String
        : server.callers.tokenFor(asSession);
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp/$credential'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, Object?>{'name': name, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      final result =
          (jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, Object?>)['result']!
              as Map<String, Object?>;
      final content =
          (result['content']! as List<Object?>).first as Map<String, Object?>;
      return (
        isError: result['isError'] == true,
        text: content['text']! as String,
        structured: result['structuredContent'],
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Files one item, through the same `apply` the watcher polls with.
  void queue({required bool approval, String? detail}) => container
      .read(attentionInboxProvider.notifier)
      .apply(
        InboxUpdate(
          watched: {key},
          waiting: approval
              ? const [
                  SessionAttention(
                    session: watched,
                    kind: AttentionKind.needsInput,
                  ),
                ]
              : const [],
          news: approval
              ? const []
              : const [(session: watched, reason: NotificationReason.finished)],
          details: detail == null ? const {} : {key: detail},
        ),
      );

  group('inbox_list', () {
    test('an agent waiting for approval is visible to another agent', () async {
      queue(approval: true);

      final structured =
          (await callTool('inbox_list')).structured! as Map<String, Object?>;
      final item =
          (structured['items']! as List<Object?>).single
              as Map<String, Object?>;

      expect(structured['unseen'], 1);
      expect(item['kind'], 'needsApproval');
      expect(item['label'], 'Fix login');
      expect(item['sessionId'], 's1');
      expect(
        item['stillTrue'],
        isTrue,
        reason: 'an agent waiting is a condition, not a past event',
      );
    });

    test('a finished turn is an event, not a condition', () async {
      queue(approval: false);

      final structured =
          (await callTool('inbox_list')).structured! as Map<String, Object?>;
      final item =
          (structured['items']! as List<Object?>).single
              as Map<String, Object?>;

      expect(item['kind'], 'finished');
      expect(item['stillTrue'], isFalse);
    });

    test('the prompt the agent is blocked on comes back', () async {
      // The reason the tool exists: without `detail` the question itself
      // reached an MCP caller only through `session_wait`'s `blockedOn`.
      queue(approval: true, detail: 'Overwrite lib/main.dart? (y/n)');

      final structured =
          (await callTool('inbox_list')).structured! as Map<String, Object?>;
      final item =
          (structured['items']! as List<Object?>).single
              as Map<String, Object?>;

      expect(item['detail'], 'Overwrite lib/main.dart? (y/n)');
    });

    test('a source that quoted nothing says nothing', () async {
      // Never synthesised, the rule `InboxItem.detail` holds itself to.
      queue(approval: true);

      final structured =
          (await callTool('inbox_list')).structured! as Map<String, Object?>;
      final item =
          (structured['items']! as List<Object?>).single
              as Map<String, Object?>;

      expect(item.containsKey('detail'), isTrue);
      expect(item['detail'], isNull);
    });

    test('an empty inbox is empty, not an error', () async {
      final structured =
          (await callTool('inbox_list')).structured! as Map<String, Object?>;
      expect(structured['items'], isEmpty);
      expect(structured['unseen'], 0);
    });
  });

  group('inbox_dismiss', () {
    test('the item leaves the inbox', () async {
      queue(approval: false);
      final id =
          (((await callTool('inbox_list')).structured!
                      as Map<String, Object?>)['items']!
                  as List<Object?>)
              .single;

      final result = await callTool('inbox_dismiss', {
        'id': (id as Map<String, Object?>)['id'],
      });

      expect(result.isError, isFalse);
      expect(container.read(attentionInboxProvider).items, isEmpty);
      // An event will not come back; the caller is told which kind it had.
      expect((result.structured! as Map)['mayReturn'], isFalse);
    });

    test('a condition says it may return, because it will', () async {
      queue(approval: true);
      final items =
          ((await callTool('inbox_list')).structured!
                  as Map<String, Object?>)['items']!
              as List<Object?>;

      final result = await callTool('inbox_dismiss', {
        'id': (items.single as Map<String, Object?>)['id'],
      });

      expect((result.structured! as Map)['mayReturn'], isTrue);
    });

    test('an unknown id is an error, not a silent success', () async {
      final result = await callTool('inbox_dismiss', {'id': 'ghost'});
      expect(result.isError, isTrue);
      expect(result.text, contains('ghost'));
    });
  });

  group('inbox_open', () {
    test('an event is done with once looked at, and says so', () async {
      queue(approval: false);
      final items =
          ((await callTool('inbox_list')).structured!
                  as Map<String, Object?>)['items']!
              as List<Object?>;

      final result = await callTool('inbox_open', {
        'id': (items.single as Map<String, Object?>)['id'],
      });

      expect(result.isError, isFalse);
      expect(container.read(attentionInboxProvider).items, isEmpty);
      expect((result.structured! as Map)['stillListed'], isFalse);
    });

    test('an open question survives being read, and says so', () async {
      // The distinction the inbox itself draws: reading a question does not
      // answer it, so the item stays — it just stops counting against the
      // badge. A tool that reported "opened" for both would tell an
      // orchestrating agent the approval had been dealt with.
      queue(approval: true);
      final items =
          ((await callTool('inbox_list')).structured!
                  as Map<String, Object?>)['items']!
              as List<Object?>;

      final result = await callTool('inbox_open', {
        'id': (items.single as Map<String, Object?>)['id'],
      });

      expect((result.structured! as Map)['stillListed'], isTrue);
      expect(container.read(attentionInboxProvider).items, hasLength(1));
      expect(container.read(attentionInboxProvider).unseen, 0);
      // Seen, so not pending — but findable with includeSeen.
      expect(
        ((await callTool('inbox_list')).structured!
            as Map<String, Object?>)['items'],
        isEmpty,
      );
      expect(
        ((await callTool('inbox_list', {'includeSeen': true})).structured!
            as Map<String, Object?>)['items'],
        hasLength(1),
      );
    });
  });
}
