import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/bot/bot_approvals.dart';
import 'package:karmashala_host/src/bot/bot_instructions.dart';
import 'package:karmashala_host/src/bot/server_bot.dart';
import 'package:karmashala_session/lineage.dart' show SessionLink;
import 'package:karmashala_session/launch.dart' show SessionView;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 11, 2, 12);
  const env = 'local';

  late AppDatabase db;
  late DataService service;
  late SessionDao sessions;
  late ServerBot bot;
  late List<AgentInstallation> installs;
  late Set<String> running;
  late Set<String> busy;
  late List<String> ended;
  late List<String> detached;
  late List<String> calls;
  late int checkoutsMade;
  late List<(String, String?)> switched;
  late String? refuseSwitch;

  AgentInstallation install(String agentId) => AgentInstallation(
    id: 'i-$agentId',
    agentId: agentId,
    executable: const EnvironmentPath(environmentId: env, path: '/bin/x'),
    createdAt: now,
  );

  ServerBot build() => ServerBot(
    database: db,
    data: service,
    environmentId: env,
    agents: () => AgentRegistry.builtIn,
    installationsIn: (_) => installs,
    defaultInstallation: (found) => null,
    ensureCheckout: () async {
      checkoutsMade++;
      db.execute(
        'INSERT OR IGNORE INTO repositories (id, project_id, name, '
        'environment_id, path, created_at) VALUES (?, ?, ?, ?, ?, ?);',
        ['rb', 'pb', 'bot', env, '/home/me/karmashala/bot', '$now'],
      );
      return RepositoryRow.of(db);
    },
    runs: running.contains,
    busy: busy.contains,
    end: (id) async {
      ended.add(id);
      running.remove(id);
    },
    cancelQueue: (id) => calls.add('cancelQueue'),
    detach: (id) async {
      calls.add('detach');
      detached.add(id);
      sessions.clearParent(id);
    },
    approvals: BotApprovals(
      database: db,
      run: (_, _, _) async => 'ran',
      post: (_, _, _) {},
      announce: service.announce,
    ),
    switchAgent: (id, installationId) async {
      if (refuseSwitch case final why?) throw StateError(why);
      switched.add((id, installationId));
      db.execute(
        'UPDATE sessions SET agent_installation_id = ? WHERE id = ?;',
        [installationId, id],
      );
    },
    now: () => now,
    newId: () => 'row${++ids}',
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 2, 12);
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    service = DataService(db, clock: () => now);
    sessions = SessionDao(db);
    installs = [install('claude-acp'), install('codex-acp'), install('codex')];
    running = {};
    busy = {};
    ended = [];
    detached = [];
    calls = [];
    switched = [];
    refuseSwitch = null;
    checkoutsMade = 0;
    bot = build();
  });

  tearDown(() => db.close());

  group('when it runs', () {
    test('nothing exists until the first message', () async {
      final state = await bot.handle(const BotStateRead()) as BotState;
      expect(state.session, isNull);
      expect(sessions.bot(), isNull);
      expect(checkoutsMade, 0);
    });

    test('bot.open makes the row, in the hidden checkout, granted', () async {
      final state = await bot.handle(const BotOpen()) as BotState;
      final row = state.session!;
      expect(row.isBot, isTrue);
      expect(row.operatorGranted, isTrue);
      expect(row.repositoryId, 'rb');
      expect(row.title, 'Bot');
      expect(row.titleByUser, isTrue);
      expect(row.view, SessionView.chat);
    });

    test('the grant holds with the global setting off and on', () async {
      db.writeMetadata(kOperateNewSessionsKey, 'false');
      await bot.handle(const BotOpen());
      expect(sessions.bot()!.operatorGranted, isTrue);
    });

    test('opening twice, even at once, is one row', () async {
      final both = await Future.wait([
        bot.handle(const BotOpen()),
        bot.handle(const BotOpen()),
      ]);
      expect(
        (both[0] as BotState).session!.id,
        (both[1] as BotState).session!.id,
      );
      expect(sessions.botIds().length, 1);
    });

    test('with no chat agent it is refused in plain words', () async {
      installs = [install('codex')];
      final state = await bot.handle(const BotStateRead()) as BotState;
      expect(state.agents, isEmpty);
      await expectLater(
        bot.handle(const BotOpen()),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.unavailable,
          ),
        ),
      );
    });
  });

  group('its agent', () {
    test('lists only agents with a chat form', () async {
      final state = await bot.handle(const BotStateRead()) as BotState;
      expect(state.agents.map((a) => a.agentId), ['claude-acp', 'codex-acp']);
    });

    test('Claude by default', () async {
      final state = await bot.handle(const BotStateRead()) as BotState;
      expect(state.agentId, 'claude-acp');
      expect(state.agentSetting, isNull);
    });

    test('the agent a person set as default, in its chat form', () async {
      bot = ServerBot(
        database: db,
        data: service,
        environmentId: env,
        agents: () => AgentRegistry.builtIn,
        installationsIn: (_) => installs,
        defaultInstallation: (found) =>
            found.firstWhere((i) => i.agentId == 'codex'),
        ensureCheckout: () async => throw StateError('unused'),
        runs: running.contains,
        busy: busy.contains,
        end: (_) async {},
        cancelQueue: (_) {},
        detach: (_) async {},
        approvals: BotApprovals(
          database: db,
          run: (_, _, _) async => null,
          post: (_, _, _) {},
          announce: service.announce,
        ),
        switchAgent: (_, _) async {},
      );
      final state = await bot.handle(const BotStateRead()) as BotState;
      expect(state.agentId, 'codex-acp');
      expect(state.notice, isNull);
    });

    test(
      'a default with no chat form: the first chat agent, and says so',
      () async {
        installs = [install('codex-acp')];
        bot = ServerBot(
          database: db,
          data: service,
          environmentId: env,
          agents: () => AgentRegistry.builtIn,
          installationsIn: (_) => [...installs, install('claudeCode')],
          defaultInstallation: (found) =>
              found.firstWhere((i) => i.agentId == 'claudeCode'),
          ensureCheckout: () async => throw StateError('unused'),
          runs: running.contains,
          busy: busy.contains,
          end: (_) async {},
          cancelQueue: (_) {},
          detach: (_) async {},
          approvals: BotApprovals(
            database: db,
            run: (_, _, _) async => null,
            post: (_, _, _) {},
            announce: service.announce,
          ),
          switchAgent: (_, _) async {},
        );
        final state = await bot.handle(const BotStateRead()) as BotState;
        expect(state.agentId, 'codex-acp');
        expect(state.notice, contains('chat'));
      },
    );

    test('setting one with no row saves it for the first message', () async {
      await bot.handle(const BotAgentSet('codex-acp'));
      expect(db.readMetadata(kBotAgentKey), 'codex-acp');
      final state = await bot.handle(const BotOpen()) as BotState;
      expect(state.session!.agentInstallationId, 'i-codex-acp');
      expect(switched, isEmpty);
    });

    test('setting one with a row switches it in place', () async {
      await bot.handle(const BotOpen());
      final state =
          await bot.handle(const BotAgentSet('codex-acp')) as BotState;
      expect(switched.single.$2, 'i-codex-acp');
      expect(state.agentId, 'codex-acp');
      expect(state.agentSetting, 'codex-acp');
    });

    test('mid-turn it is refused and nothing is saved', () async {
      await bot.handle(const BotOpen());
      refuseSwitch = 'A turn is running in this session.';
      await expectLater(
        bot.handle(const BotAgentSet('codex-acp')),
        throwsA(isA<DataRefused>()),
      );
      final cleared = await bot.handle(const BotStateRead()) as BotState;
      expect(cleared.agentSetting, isNull);
    });

    test('an agent with no chat form is refused', () async {
      await expectLater(
        bot.handle(const BotAgentSet('codex')),
        throwsA(isA<DataRefused>()),
      );
    });

    test('back to the default clears the setting', () async {
      await bot.handle(const BotAgentSet('codex-acp'));
      final state = await bot.handle(const BotAgentSet(null)) as BotState;
      expect(state.agentSetting, isNull);
      expect(state.agentId, 'claude-acp');
    });
  });

  group('idle', () {
    test('stops after 30 minutes with nothing happening', () async {
      final row = (await bot.handle(const BotOpen()) as BotState).session!;
      running.add(row.id);
      bot.tick();
      now = now.add(const Duration(minutes: 29));
      bot.tick();
      expect(ended, isEmpty);
      now = now.add(const Duration(minutes: 1));
      bot.tick();
      expect(ended, [row.id]);
      expect(sessions.bot()!.isArchived, isFalse);
      expect(kBotIdleStop, const Duration(minutes: 30));
    });

    test('a turn starts the 30 minutes over', () async {
      final row = (await bot.handle(const BotOpen()) as BotState).session!;
      running.add(row.id);
      bot.tick();
      now = now.add(const Duration(minutes: 29));
      busy.add(row.id);
      bot.tick();
      busy.remove(row.id);
      now = now.add(const Duration(minutes: 2));
      bot.tick();
      expect(ended, isEmpty);
    });

    test('a stopped bot is left alone', () async {
      await bot.handle(const BotOpen());
      bot.tick();
      now = now.add(const Duration(hours: 2));
      bot.tick();
      expect(ended, isEmpty);
    });
  });

  group('clear', () {
    late Session row;

    setUp(() async {
      row = (await bot.handle(const BotOpen()) as BotState).session!;
      running.add(row.id);
      for (final id in ['child1', 'child2']) {
        sessions.insertWithPrimaryRepository(
          row
              .copyWith(id: id, title: id)
              .copyWithParent(row.id, SessionLink.spawn),
        );
      }
    });

    test('a running turn blocks it', () async {
      busy.add(row.id);
      await expectLater(
        bot.handle(const BotClear()),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.conflict,
          ),
        ),
      );
      expect(sessions.bot(), isNotNull);
      expect(detached, isEmpty);
    });

    test(
      'detaches first, ends and archives, and the row stays hidden',
      () async {
        final state = await bot.handle(const BotClear()) as BotState;
        expect(state.session, isNull);
        expect(detached, ['child1', 'child2']);
        expect(ended, [row.id]);
        expect(sessions.getById(row.id)!.isArchived, isTrue);
        expect(sessions.bot(), isNull);
        expect(sessions.getById('child1')!.parentSessionId, isNull);
        expect(calls.indexOf('detach'), lessThan(calls.indexOf('cancelQueue')));
        expect(service.botView.rows, contains(row.id));
      },
    );

    test('a row that never ran does not stay live', () async {
      sessions.updateStatus(row.id, SessionStatus.running);
      await bot.handle(const BotClear());
      expect(sessions.getById(row.id)!.status, SessionStatus.completed);
      expect(
        sessions.getClaimingLive().map((s) => s.id),
        isNot(contains(row.id)),
      );
    });

    test('the next open makes a new row in the same folder', () async {
      await bot.handle(const BotClear());
      final next = (await bot.handle(const BotOpen()) as BotState).session!;
      expect(next.id, isNot(row.id));
      expect(next.repositoryId, row.repositoryId);
    });

    test('nothing to clear is no error', () async {
      await bot.handle(const BotClear());
      final state = await bot.handle(const BotClear()) as BotState;
      expect(state.session, isNull);
    });
  });

  group('its instructions', () {
    test('say what the design asks, and no more than it promises', () {
      final text = kBotInstructions;
      expect(text, contains('MEMORY.md'));
      expect(text, contains('2,000 characters'));
      expect(text, contains('existing sessions'));
      expect(text, contains('which one'));
      expect(text.toLowerCase(), isNot(contains('sandbox')));
      expect(text, contains('end your turn'));
    });

    test('the files cover Claude and Codex; another gets a preamble', () {
      expect(kBotFiles.keys, containsAll(['AGENTS.md', 'CLAUDE.md']));
      expect(botFilesCover(const ['CLAUDE.md']), isTrue);
      expect(botFilesCover(const ['GEMINI.md']), isFalse);
      expect(botFilesCover(const []), isFalse);
      expect(withBotPreamble('hello'), contains('hello'));
      expect(withBotPreamble('hello'), contains('MEMORY.md'));
    });
  });
}

var ids = 0;

extension on Session {
  Session copyWithParent(String parent, SessionLink link) => Session(
    id: id,
    repositoryId: repositoryId,
    agentInstallationId: agentInstallationId,
    title: title,
    useWorktree: useWorktree,
    status: status,
    createdAt: createdAt,
    parentSessionId: parent,
    parentLink: link,
  );
}

/// Reads back the one repository the fake made.
abstract final class RepositoryRow {
  static Repository of(AppDatabase db) => RepositoryDao(db).getById('rb')!;
}
