import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/attention/server_attention.dart';
import 'package:karmashala_host/src/attention/server_session_status.dart';
import 'package:karmashala_host/src/mcp/tools/inbox_tool_set.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:test/test.dart';

final _start = DateTime.utc(2026, 9, 27, 9);

class _Clock implements Clock {
  @override
  DateTime nowUtc() => _start;
}

/// `inbox_list`, `inbox_open`, `inbox_dismiss` answered by the server from
/// its own inbox (slice 5c; the app's `attention_tools_test`, moved): an
/// agent orchestrating others sees what waits on somebody, app or no app.
void main() {
  late ServerAttention attention;
  late InboxToolSet tools;
  late int windows;
  late List<DataChange> told;

  const session = WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'cli-1'),
    label: 'Fix login',
    openId: 's1',
    imported: false,
  );

  setUp(() {
    windows = 1;
    told = [];
    final reports = AgentHookReports();
    attention = ServerAttention(
      status: ServerSessionStatus(
        statusService: AgentStatusService(
          registry: AgentRegistry.builtIn,
          hookReports: reports,
          clock: _Clock(),
        ),
        agents: AgentRegistry.builtIn,
        loadSessions: () => const [],
        clock: _Clock(),
      ),
      tell: told.addAll,
      clock: _Clock(),
      followUps: () => const [],
      resolveFollowUp: (_) {},
      sessionOf: (_) => null,
      windows: () => windows,
    );
    tools = InboxToolSet(attention);
  });

  tearDown(() => attention.close());

  void queue({required bool approval, String? detail}) => attention.handle(
    InboxRaise(
      InboxItem(
        session: session,
        kind: approval ? InboxItemKind.needsApproval : InboxItemKind.finished,
        at: _start,
        detail: detail,
      ),
    ),
    null,
  );

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
  ]) async =>
      (await tools.call(tool, arguments, 'caller'))! as Map<String, Object?>;

  Map<String, Object?> onlyItem(Map<String, Object?> listed) =>
      (listed['items']! as List<Object?>).single! as Map<String, Object?>;

  test('the schemas are the app\'s three, unchanged in name', () {
    expect(
      [for (final s in tools.schemas) s['name']],
      ['inbox_list', 'inbox_open', 'inbox_dismiss'],
    );
  });

  group('inbox_list', () {
    test('an agent waiting for approval is visible to another agent', () async {
      queue(approval: true);
      final listed = await call('inbox_list');
      final item = onlyItem(listed);
      expect(listed['unseen'], 1);
      expect(item['kind'], 'needsApproval');
      expect(item['label'], 'Fix login');
      expect(item['sessionId'], 's1');
      expect(item['stillTrue'], isTrue);
    });

    test('a finished turn is an event, not a condition', () async {
      queue(approval: false);
      expect(onlyItem(await call('inbox_list'))['stillTrue'], isFalse);
    });

    test(
      'the prompt the agent is blocked on comes back, and only it',
      () async {
        queue(approval: true, detail: 'Overwrite lib/main.dart? (y/n)');
        expect(
          onlyItem(await call('inbox_list'))['detail'],
          'Overwrite lib/main.dart? (y/n)',
        );
      },
    );

    test('an empty inbox is empty, not an error', () async {
      final listed = await call('inbox_list');
      expect(listed['items'], isEmpty);
      expect(listed['unseen'], 0);
    });
  });

  group('inbox_dismiss', () {
    test('an event leaves and will not come back', () async {
      queue(approval: false);
      final id = onlyItem(await call('inbox_list'))['id'];
      final result = await call('inbox_dismiss', {'id': id});
      expect(result['mayReturn'], isFalse);
      expect(attention.inbox.isEmpty, isTrue);
    });

    test('a condition says it may return, because it will', () async {
      queue(approval: true);
      final id = onlyItem(await call('inbox_list'))['id'];
      expect((await call('inbox_dismiss', {'id': id}))['mayReturn'], isTrue);
    });

    test('an unknown id is an error, not a silent success', () {
      expect(
        call('inbox_dismiss', {'id': 'ghost'}),
        throwsA(
          isA<StateError>().having((e) => '$e', 'text', contains('ghost')),
        ),
      );
    });
  });

  group('inbox_open', () {
    test(
      'an event is done with once looked at, and a window shows it',
      () async {
        queue(approval: false);
        final id = onlyItem(await call('inbox_list'))['id'];
        final result = await call('inbox_open', {'id': id});
        await Future<void>.delayed(Duration.zero);
        expect(result['stillListed'], isFalse);
        expect(attention.inbox.isEmpty, isTrue);
        expect(told.whereType<InboxOpenWanted>().single.openId, 's1');
        expect(result['note'], isNot(contains('No Karmashala window')));
      },
    );

    test('an open question survives being read, and says so', () async {
      queue(approval: true);
      final id = onlyItem(await call('inbox_list'))['id'];
      final result = await call('inbox_open', {'id': id});
      expect(result['stillListed'], isTrue);
      expect(attention.inbox.unseen, 0);
      expect((await call('inbox_list'))['items'], isEmpty);
      expect(
        (await call('inbox_list', {'includeSeen': true}))['items'],
        hasLength(1),
      );
    });

    test(
      'with no window connected the answer says nothing was shown',
      () async {
        windows = 0;
        queue(approval: true);
        final id = onlyItem(await call('inbox_list'))['id'];
        final result = await call('inbox_open', {'id': id});
        expect(result['note'], contains('No Karmashala window is connected'));
        expect(result['seen'], isTrue);
      },
    );

    test('an id is required', () {
      expect(call('inbox_open'), throwsA(isA<ArgumentError>()));
    });
  });
}
