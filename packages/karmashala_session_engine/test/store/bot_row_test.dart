import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:test/test.dart';

import '../support/store_fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = SessionDao(db);
    seedWorkspace(db);
  });
  tearDown(() => db.close());

  test("a client cannot make a bot: insert ignores the row's own role", () {
    dao.insert(session().copyWith(role: kSessionRoleBot));
    expect(dao.getById('s1')!.isBot, isFalse);
    expect(dao.getById('s1')!.role, isNull);
  });

  test('insertBot writes the role and always the grant', () {
    expect(db.readMetadata(kOperateNewSessionsKey), isNull);
    dao.insertBot(session(id: 'bot'));
    final bot = dao.getById('bot')!;
    expect(bot.isBot, isTrue);
    expect(bot.operatorGranted, isTrue);
  });

  test('write cannot take the grant away from a bot row', () {
    dao.insertBot(session(id: 'bot'));
    dao.write(dao.getById('bot')!.copyWith(operatorGranted: false));
    expect(dao.getById('bot')!.operatorGranted, isTrue);
  });

  test('write still sets it on an ordinary row', () {
    dao.insert(session());
    dao.write(dao.getById('s1')!.copyWith(operatorGranted: true));
    expect(dao.getById('s1')!.operatorGranted, isTrue);
  });

  test('a second unarchived bot row is refused by the store', () {
    dao.insertBot(session(id: 'bot'));
    expect(
      () => dao.insertBot(session(id: 'bot2')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('an archived bot row makes way for a new one', () {
    dao.insertBot(session(id: 'bot'));
    dao.markArchived('bot', testTime);
    dao.insertBot(session(id: 'bot2'));
    expect(dao.bot()!.id, 'bot2');
    expect(dao.botIds(), {'bot', 'bot2'});
  });

  test('getAll and direct lookups stay complete; getPublic does not', () {
    dao.insert(session());
    dao.insertBot(session(id: 'bot'));
    expect(dao.getAll().map((s) => s.id), containsAll(['s1', 'bot']));
    expect(dao.getById('bot'), isNotNull);
    expect(dao.getPublic().map((s) => s.id), ['s1']);
  });

  test('getUnattributed leaves the bot alone', () {
    dao.insertBot(session(id: 'bot'));
    expect(dao.getUnattributed(), isEmpty);
  });

  test('getClaimingLivePublic leaves the bot out', () {
    dao.insert(session(status: SessionStatus.running));
    dao.insertBot(session(id: 'bot', status: SessionStatus.running));
    expect(dao.getClaimingLive().length, 2);
    expect(dao.getClaimingLivePublic().map((s) => s.id), ['s1']);
  });

  test('the role and viaBot travel on the wire; old rows read as none', () {
    final bot = session(
      id: 'bot',
    ).copyWith(role: kSessionRoleBot, viaBot: true);
    final back = Session.fromJson(bot.toJson());
    expect(back.role, kSessionRoleBot);
    expect(back.viaBot, isTrue);
    final plain = session().toJson();
    expect(plain.containsKey('role'), isFalse);
    expect(plain.containsKey('viaBot'), isFalse);
    expect(Session.fromJson(plain).isBot, isFalse);
  });

  group('approvals', () {
    late BotApprovalDao approvals;
    final at = DateTime.utc(2026, 11, 2, 12);

    BotApproval pending(String id, {DateTime? expires}) => BotApproval(
      id: id,
      sessionId: 'bot',
      tool: 'session_archive',
      arguments: const {'sessionId': 's1'},
      summary: 'Archive "Fix it"',
      state: BotApprovalState.pending,
      requestedAt: at,
      expiresAt: expires ?? at.add(kBotApprovalLifetime),
    );

    setUp(() {
      approvals = BotApprovalDao(db);
      dao.insertBot(session(id: 'bot'));
    });

    test('kept with exact tool and arguments', () {
      approvals.insert(pending('a'));
      final read = approvals.getById('a')!;
      expect(read.tool, 'session_archive');
      expect(read.arguments, {'sessionId': 's1'});
      expect(read.state, BotApprovalState.pending);
      expect(kBotApprovalLifetime, const Duration(minutes: 10));
    });

    test('consuming is atomic: a second Yes gets nothing', () {
      approvals.insert(pending('a'));
      expect(
        approvals.consume('a', to: BotApprovalState.running, at: at, by: 'app'),
        isNotNull,
      );
      expect(
        approvals.consume('a', to: BotApprovalState.running, at: at, by: 'app'),
        isNull,
      );
    });

    test('a request past its time cannot be consumed', () {
      approvals.insert(pending('a', expires: at));
      expect(
        approvals.consume(
          'a',
          to: BotApprovalState.running,
          at: at.add(const Duration(seconds: 1)),
          by: 'app',
        ),
        isNull,
      );
    });

    test('expireDue takes only what is past its time', () {
      approvals.insert(pending('old', expires: at));
      approvals.insert(pending('new', expires: at.add(kBotApprovalLifetime)));
      final expired = approvals.expireDue(at.add(const Duration(minutes: 1)));
      expect(expired.map((a) => a.id), ['old']);
      expect(approvals.getById('old')!.state, BotApprovalState.expired);
      expect(approvals.getById('new')!.state, BotApprovalState.pending);
    });

    test('expireAll takes every pending request of a session', () {
      approvals.insert(pending('a'));
      approvals.insert(pending('b'));
      expect(approvals.expireAll('bot', at: at).length, 2);
      expect(approvals.pending('bot'), isEmpty);
    });

    test('finish records the outcome; a running one is found at a restart', () {
      approvals.insert(pending('a'));
      approvals.consume('a', to: BotApprovalState.running, at: at, by: 'app');
      expect(approvals.running().map((a) => a.id), ['a']);
      approvals.finish('a', state: BotApprovalState.done, outcome: 'it ran');
      expect(approvals.getById('a')!.outcome, 'it ran');
      expect(approvals.running(), isEmpty);
    });

    test('a request goes with its session', () {
      approvals.insert(pending('a'));
      dao.delete('bot');
      expect(approvals.getById('a'), isNull);
    });
  });
}
