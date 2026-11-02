import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/bot/bot_view.dart';
import 'package:karmashala_host/src/data/bot_work.dart';
import 'package:karmashala_host/src/serve/server_features.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/lineage.dart' show SessionLink;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart' show SessionRecap;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

class _Bot implements BotWork {
  @override
  Future<Object?> handle(BotRequest<Object?> request, {String? device}) async =>
      const BotState();
}

/// The bot's row and project exist for the server and for nobody else: not
/// in a snapshot, not in an incremental change, not after a restart, and not
/// for an older client, which never asks to follow it.
void main() {
  final at = DateTime.utc(2026, 11, 2, 12);

  late AppDatabase db;
  late DataService service;
  late SessionDao sessions;
  late DataSession older;
  late List<DataChanges> toldOlder;
  late DataSession panel;
  late List<DataChanges> toldPanel;

  Session row(String id, {String? parent, SessionLink? link}) => Session(
    id: id,
    repositoryId: id == 'bot' ? 'rb' : 'r1',
    agentInstallationId: 'a1',
    title: id,
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: at,
    parentSessionId: parent,
    parentLink: link,
  );

  void seed() {
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      'created_at, kind) VALUES (?, ?, ?, ?, ?, ?);',
      ['pb', 'Bot', 'local', '/home/me/karmashala/bot', '$at', Project.botKind],
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      'created_at) VALUES (?, ?, ?, ?, ?);',
      ['p1', 'Shop', 'local', '/src/shop', '$at'],
    );
    for (final (id, project, path) in const [
      ('rb', 'pb', '/home/me/karmashala/bot'),
      ('r1', 'p1', '/src/shop'),
    ]) {
      db.execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, '
        'path, created_at) VALUES (?, ?, ?, ?, ?, ?);',
        [id, project, id, 'local', path, '$at'],
      );
    }
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', 'claudeCode', 'local', '/bin/claude', '$at', 1],
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    service = DataService(db, clock: () => at);
    sessions = SessionDao(db);
    seed();
    sessions.insertBot(row('bot'));
    sessions.insertWithPrimaryRepository(row('plain'));
    sessions.insertWithPrimaryRepository(
      row('child', parent: 'bot', link: SessionLink.spawn),
    );
    toldOlder = [];
    older = service.open(toldOlder.add)..handle(const DataSubscribe());
    toldPanel = [];
    panel = service.open(toldPanel.add)..handle(const DataSubscribe());
    panel.followBot();
  });

  tearDown(() => db.close());

  List<DataChange> all(List<DataChanges> told) => [
    for (final batch in told) ...batch.changes,
  ];

  group('snapshots', () {
    test('sessions.list has no bot row, nor anything of it', () {
      SessionRecapDao(db).write(
        SessionRecap(
          sessionId: 'bot',
          text: 'x',
          agentId: 'claudeCode',
          turnCount: 1,
          writtenAt: at,
        ),
      );
      final list = older.handle(const SessionsList()).value;
      expect(list.sessions.map((s) => s.id), isNot(contains('bot')));
      expect(list.links.keys, isNot(contains('bot')));
      expect(list.recaps, isEmpty);
    });

    test('workspaces.list has no bot project or checkout', () {
      final list = older.handle(const WorkspaceList()).value;
      expect(list.projects.map((p) => p.id), ['p1']);
      expect(list.repositories.map((r) => r.id), ['r1']);
    });

    test('a child of the bot has no parent, and says so', () {
      final child = older
          .handle(const SessionsList())
          .value
          .sessions
          .firstWhere((s) => s.id == 'child');
      expect(child.parentSessionId, isNull);
      expect(child.parentLink, isNull);
      expect(child.viaBot, isTrue);
    });

    test('the server itself still reads everything', () {
      final list = service.applyAsServer(const SessionsList());
      expect(list.sessions.map((s) => s.id), contains('bot'));
      expect(
        list.sessions.firstWhere((s) => s.id == 'child').parentSessionId,
        'bot',
      );
      expect(service.applyAsServer(const WorkspaceList()).projects.length, 2);
    });

    test('a direct lookup in the store is complete', () {
      expect(sessions.getById('bot'), isNotNull);
      expect(sessions.getAll().map((s) => s.id), contains('bot'));
    });
  });

  group('incremental changes', () {
    test('a row the server wrote is told to no ordinary client', () {
      service.announceSessions(['bot']);
      expect(all(toldOlder), isEmpty);
    });

    test('a follower hears the bot as its own change, not a session row', () {
      service.announceSessions(['bot']);
      final heard = all(toldPanel);
      expect(heard.whereType<SessionRowChanged>(), isEmpty);
      expect(heard.whereType<BotRowChanged>().single.row.id, 'bot');
      expect(heard.whereType<SessionLinksChanged>(), isEmpty);
    });

    test('a batch keeps its revision though nothing in it is for you', () {
      service.announceSessions(['bot']);
      service.announceSessions(['plain']);
      expect(toldOlder.last.revision, service.revision);
      expect(
        all(toldOlder).whereType<SessionRowChanged>().single.session.id,
        'plain',
      );
    });

    test('a child of the bot is told with no parent', () {
      service.announceSessions(['child']);
      final told = all(toldOlder).whereType<SessionRowChanged>().single;
      expect(told.session.parentSessionId, isNull);
      expect(told.session.viaBot, isTrue);
    });

    test('status, queue and news of the bot go to followers alone', () {
      const session = WatchedSession(
        key: AgentSessionKey('claude-acp', 'c'),
        label: 'Bot',
        openId: 'bot',
        imported: false,
      );
      service.announce([
        const SessionStatusRemoved('bot'),
        const SessionQueueChanged(sessionId: 'bot', messages: []),
        InboxOpenWanted(openId: session.openId, imported: false),
      ]);
      expect(all(toldOlder), isEmpty);
      expect(all(toldPanel).length, 3);
    });

    test('the inbox loses the bot\'s items for an ordinary client only', () {
      const bot = WatchedSession(
        key: AgentSessionKey('claude-acp', 'c'),
        label: 'Bot',
        openId: 'bot',
        imported: false,
      );
      const plain = WatchedSession(
        key: AgentSessionKey('claude-acp', 'd'),
        label: 'Plain',
        openId: 'plain',
        imported: false,
      );
      service.announce([
        InboxChanged(
          AttentionSnapshot(
            inbox: AttentionInbox(
              items: [
                InboxItem(session: bot, kind: InboxItemKind.failed, at: at),
                InboxItem(session: plain, kind: InboxItemKind.failed, at: at),
              ],
            ),
          ),
        ),
      ]);
      InboxChanged inbox(List<DataChanges> told) =>
          all(told).whereType<InboxChanged>().single;
      expect(inbox(toldOlder).snapshot.inbox.items.single.label, 'Plain');
      expect(inbox(toldPanel).snapshot.inbox.items.length, 2);
    });

    test('a bot project change is told to nobody', () {
      service.announce([
        ProjectChanged(
          Project(
            id: 'pb',
            name: 'Bot',
            root: const EnvironmentPath(
              environmentId: 'local',
              path: '/home/me/karmashala/bot',
            ),
            createdAt: at,
            kind: Project.botKind,
          ),
        ),
      ]);
      expect(all(toldOlder), isEmpty);
      expect(all(toldPanel), isEmpty);
    });

    test('a follow-up of the bot is told to nobody', () {
      service.announce([
        FollowUpChanged(
          FollowUp(
            id: 1,
            sessionId: 'bot',
            reason: FollowUpReason.endedInFailure,
            ending: SessionEnding.failed,
            summary: 's',
            raisedAt: at,
          ),
        ),
      ]);
      expect(all(toldOlder), isEmpty);
      expect(all(toldPanel), isEmpty);
    });

    test('the origin\'s own reply is viewed too', () {
      final reply = older.handle(
        SessionEdit('child', SessionPatch.rename('Renamed')),
      );
      expect(reply.value.parentSessionId, isNull);
      expect(reply.value.viaBot, isTrue);
      expect(
        reply.changes.whereType<SessionRowChanged>().single.session.viaBot,
        isTrue,
      );
    });
  });

  group('a client cannot reach the bot row by id', () {
    test('it cannot take the grant away', () {
      older.handle(SessionEdit('bot', SessionPatch.operator(granted: false)));
      expect(sessions.getById('bot')!.operatorGranted, isTrue);
    });

    test('it cannot delete, archive or attach under it', () {
      expect(
        () => older.handle(const SessionDelete('bot')),
        throwsA(isA<DataRefused>()),
      );
      expect(
        () => older.handle(const SessionsArchive(['bot'])),
        throwsA(isA<DataRefused>()),
      );
      expect(
        () => older.handle(const SessionsDeleteMany(sessionIds: ['bot'])),
        throwsA(isA<DataRefused>()),
      );
      expect(sessions.getById('bot')!.isArchived, isFalse);
    });

    test('a client cannot create a bot through sessions.create', () {
      older.handle(SessionCreate(row('sneak').copyWith(role: kSessionRoleBot)));
      expect(sessions.getById('sneak')!.isBot, isFalse);
    });
  });

  group('activity', () {
    test('the log hides the bot, though the store keeps its entries', () {
      final page = older.handle(
        ActivityRange(
          from: at.subtract(const Duration(days: 1)),
          to: at.add(const Duration(days: 1)),
        ),
      );
      expect(
        page.value.entries.map((e) => e.sessionId),
        isNot(contains('bot')),
      );
    });
  });

  test('a restart reads the same: nothing of it comes back', () {
    final after = DataService(db, clock: () => at);
    final link = after.open((_) {});
    final list = link.handle(const SessionsList()).value;
    expect(list.sessions.map((s) => s.id), isNot(contains('bot')));
    expect(list.sessions.firstWhere((s) => s.id == 'child').viaBot, isTrue);
    expect(sessions.bot()!.id, 'bot');
  });

  test('BotView is empty, and does nothing, on a server with no bot', () {
    final fresh = AppDatabase.memory();
    addTearDown(fresh.close);
    expect(BotView.of(fresh).isEmpty, isTrue);
  });

  test('on a server with no row yet, the bot\'s own changes still stay with '
      'those who follow', () {
    final fresh = AppDatabase.memory();
    addTearDown(fresh.close);
    final none = BotView.of(fresh);
    const change = BotAgentChanged(agentId: 'claude-acp');
    expect(none.changes(const [change], follower: false), isEmpty);
    expect(none.changes(const [change], follower: true), hasLength(1));
  });

  test('a phone needs its grants for the bot, as for what it stands for', () {
    final limited = CapabilitySet.of([Capability.viewSessions]);
    expect(phoneRefusal(const BotStateRead(), grants: limited), isNull);
    expect(phoneRefusal(const BotSubscribe(), grants: limited), isNull);
    expect(phoneRefusal(const BotOpen(), grants: limited), contains('start'));
    expect(phoneRefusal(const BotClear(), grants: limited), contains('start'));
    expect(
      phoneRefusal(const BotAgentSet(null), grants: limited),
      contains('start'),
    );
    expect(
      phoneRefusal(
        const BotApprovalAnswer('x', approve: true),
        grants: limited,
      ),
      contains('approve'),
    );
  });

  test(
    'every bot request is answered later, and unavailable with no bot',
    () async {
      expect(DataSession.isAnsweredLater(const BotStateRead()), isTrue);
      await expectLater(
        older.handleLater(const BotStateRead()),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.unavailable,
          ),
        ),
      );
    },
  );

  test('bot.subscribe makes a link a follower, and only that link', () async {
    service.botWork = _Bot();
    await older.handleLater(const BotSubscribe());
    service.announceSessions(['bot']);
    expect(all(toldOlder).whereType<BotRowChanged>(), hasLength(1));
    final other = <DataChanges>[];
    service.open(other.add).handle(const DataSubscribe());
    service.announceSessions(['bot']);
    expect(all(other).whereType<BotRowChanged>(), isEmpty);
  });

  test('the server advertises the capability', () {
    expect(kServerFeatures, contains(BotOpen.feature));
  });

  test(
    'a newer client against an older server: unknown request is refused',
    () {
      expect(BotOpen.feature, 'bot');
    },
  );
}
