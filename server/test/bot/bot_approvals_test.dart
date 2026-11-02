import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/bot/bot_approvals.dart';
import 'package:karmashala_host/src/mcp/mcp_tool_relay.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tools.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

class _Recording extends ServerToolSet {
  final ran = <(String, Map<String, dynamic>, String?)>[];
  Object? answer = 'it ran';
  Object? failure;
  Completer<void>? hold;

  @override
  List<Map<String, Object?>> get schemas => [
    for (final name in const [
      'session_archive',
      'session_end',
      'terminal_run',
      'list_sessions',
    ])
      {'name': name},
  ];

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) async {
    ran.add((tool, arguments, callerSessionId));
    await hold?.future;
    if (failure case final failure?) throw failure;
    return answer;
  }
}

void main() {
  var now = DateTime.utc(2026, 11, 2, 12);

  late AppDatabase db;
  late SessionDao sessions;
  late _Recording tool;
  late McpToolRelay relay;
  late BotApprovals approvals;
  late List<(String, String)> posted;
  late List<DataChange> told;
  late List<InboxItem> raised;
  late List<String> retired;

  Session row(String id, {String? parent}) => Session(
    id: id,
    repositoryId: 'r',
    agentInstallationId: 'a',
    title: 'Fix $id',
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: now,
    parentSessionId: parent,
  );

  BotApprovals build() => BotApprovals(
    database: db,
    run: relay.runApproved,
    post: (sessionId, text, originId) => posted.add((sessionId, text)),
    announce: told.addAll,
    raise: raised.add,
    retire: retired.add,
    now: () => now,
    newId: () => 'ap${raisedIds++}',
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 2, 12);
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    sessions = SessionDao(db);
    sessions.insertBot(row('bot'));
    sessions.insertWithPrimaryRepository(row('plain'));
    sessions.insertWithPrimaryRepository(row('child', parent: 'bot'));
    tool = _Recording();
    posted = [];
    told = [];
    raised = [];
    retired = [];
    relay = McpToolRelay(tools: ServerTools([tool]));
    approvals = build();
    relay.approvalGate = approvals.hold;
  });

  tearDown(() {
    approvals.close();
    db.close();
  });

  Future<String> refused(String name, Map<String, dynamic> arguments) async {
    try {
      await relay.call(name, arguments, 'bot');
    } on McpToolRelayFailure catch (failure) {
      return failure.message;
    }
    fail('$name ran');
  }

  String pendingId() => BotApprovalDao(db).pending('bot').single.id;

  group('the gate', () {
    test(
      'a destructive tool returns at once, not done, and does not run',
      () async {
        final said = await refused('session_end', {'sessionId': 'plain'});
        expect(said, contains('Not done'));
        expect(said, contains('approval'));
        expect(tool.ran, isEmpty);
        final request = BotApprovalDao(db).pending('bot').single;
        expect(request.tool, 'session_end');
        expect(request.arguments, {'sessionId': 'plain'});
        expect(request.expiresAt, now.add(const Duration(minutes: 10)));
      },
    );

    test('a person sees the tool and its target in words', () async {
      await refused('session_end', {'sessionId': 'plain'});
      expect(
        BotApprovalDao(db).pending('bot').single.summary,
        contains('Fix plain'),
      );
      expect(raised.single.kind, InboxItemKind.botApproval);
      expect(raised.single.session.openId, 'bot');
      expect(raised.single.detail, contains('Fix plain'));
      expect(
        told.whereType<BotApprovalChanged>().single.approval.state,
        BotApprovalState.pending,
      );
    });

    test('a read-only tool just runs', () async {
      await relay.call('list_sessions', {}, 'bot');
      expect(tool.ran.single.$1, 'list_sessions');
      expect(BotApprovalDao(db).pending('bot'), isEmpty);
    });

    test(
      'an ordinary session is not asked: the gate is the bot\'s alone',
      () async {
        await relay.call('session_end', {'sessionId': 'x'}, 'plain');
        expect(tool.ran.single.$3, 'plain');
      },
    );

    test(
      'session_end of a session the bot started needs no approval',
      () async {
        await relay.call('session_end', {'sessionId': 'child'}, 'bot');
        expect(tool.ran.single.$1, 'session_end');
      },
    );

    test('session_end of any other target asks', () async {
      await refused('session_end', {'sessionId': 'plain'});
      await refused('session_end', {});
      expect(tool.ran, isEmpty);
      expect(BotApprovalDao(db).pending('bot').length, 2);
    });

    test('the same call again is the same request, not a second', () async {
      await refused('terminal_run', {'command': 'rm x'});
      await refused('terminal_run', {'command': 'rm x'});
      expect(BotApprovalDao(db).pending('bot').length, 1);
      await refused('terminal_run', {'command': 'rm y'});
      expect(BotApprovalDao(db).pending('bot').length, 2);
    });
  });

  group('Yes', () {
    test('runs exactly the recorded call, once, as the bot', () async {
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      final answered = await approvals.answer(id, approve: true, by: 'app');
      expect(answered.state, BotApprovalState.running);
      await approvals.settled;
      expect(tool.ran.single.$1, 'session_end');
      expect(tool.ran.single.$2, {'sessionId': 'plain'});
      expect(tool.ran.single.$3, 'bot');
      expect(BotApprovalDao(db).getById(id)!.state, BotApprovalState.done);
      expect(retired, ['botApproval:$id']);
    });

    test('a second Yes is refused, and runs nothing more', () async {
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      await approvals.answer(id, approve: true, by: 'app');
      await expectLater(
        approvals.answer(id, approve: true, by: 'device:phone'),
        throwsA(isA<DataRefused>()),
      );
      await approvals.settled;
      expect(tool.ran.length, 1);
    });

    test('two at once run it once', () async {
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      final both = await Future.wait([
        approvals
            .answer(id, approve: true, by: 'a')
            .then((_) => 1, onError: (_) => 0),
        approvals
            .answer(id, approve: true, by: 'b')
            .then((_) => 1, onError: (_) => 0),
      ]);
      await approvals.settled;
      expect(both.reduce((a, b) => a + b), 1);
      expect(tool.ran.length, 1);
    });

    test('the outcome goes to the bot as one message', () async {
      await refused('session_end', {'sessionId': 'plain'});
      await approvals.answer(pendingId(), approve: true, by: 'app');
      await approvals.settled;
      expect(posted.length, 1);
      expect(posted.single.$1, 'bot');
      expect(posted.single.$2, contains('it ran'));
      expect(posted.single.$2, contains('do not run it again'));
    });

    test('a failure is told as a failure', () async {
      tool.failure = StateError('nothing to archive');
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      await approvals.answer(id, approve: true, by: 'app');
      await approvals.settled;
      expect(posted.single.$2, contains('nothing to archive'));
      expect(posted.single.$2, contains('failed'));
      expect(BotApprovalDao(db).getById(id)!.state, BotApprovalState.done);
    });
  });

  group('No, and expiry', () {
    test('No runs nothing, and says so once', () async {
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      final answered = await approvals.answer(id, approve: false, by: 'app');
      expect(answered.state, BotApprovalState.denied);
      await approvals.settled;
      expect(tool.ran, isEmpty);
      expect(posted.single.$2, contains('No'));
      expect(posted.single.$2, contains('Nothing ran'));
      expect(retired, ['botApproval:$id']);
    });

    test('past its time it expires and runs nothing', () async {
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      now = now.add(const Duration(minutes: 10, seconds: 1));
      await expectLater(
        approvals.answer(id, approve: true, by: 'app'),
        throwsA(isA<DataRefused>()),
      );
      approvals.sweep();
      expect(BotApprovalDao(db).getById(id)!.state, BotApprovalState.expired);
      expect(tool.ran, isEmpty);
      expect(posted.single.$2, contains('Nothing ran'));
    });
  });

  group('a restart', () {
    test('a pending request survives, and can be answered', () async {
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      approvals.close();
      approvals = build()..start();
      await approvals.answer(id, approve: true, by: 'app');
      await approvals.settled;
      expect(tool.ran.length, 1);
    });

    test('one past its time is expired at the start', () async {
      await refused('session_end', {'sessionId': 'plain'});
      final id = pendingId();
      approvals.close();
      now = now.add(const Duration(hours: 1));
      approvals = build()..start();
      expect(BotApprovalDao(db).getById(id)!.state, BotApprovalState.expired);
    });

    test(
      'a call a stop cut off is not run again, and the bot is told',
      () async {
        tool.hold = Completer();
        await refused('session_end', {'sessionId': 'plain'});
        final id = pendingId();
        await approvals.answer(id, approve: true, by: 'app');
        approvals.close();
        approvals = build()..start();
        expect(
          BotApprovalDao(db).getById(id)!.state,
          BotApprovalState.interrupted,
        );
        expect(posted.single.$2, contains('may have run'));
        expect(tool.ran.length, 1);
        tool.hold!.complete();
      },
    );
  });

  test('clear expires everything and tells the bot nothing', () async {
    await refused('session_end', {'sessionId': 'plain'});
    await refused('terminal_run', {'command': 'x'});
    approvals.clear('bot');
    expect(BotApprovalDao(db).pending('bot'), isEmpty);
    expect(posted, isEmpty);
    expect(retired.length, 2);
  });
}

var raisedIds = 0;
