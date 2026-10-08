import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/read.dart' show ConversationPresence;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/session_handoffs.dart';
import 'package:karmashala_host/src/sessions/launch/launch_settings.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// A session nothing runs never traps what is queued for it: the queue
/// drains once `launches.resume` brings it back and it goes idle, and a send
/// to it resumes it — with the head as its opening prompt when the agent
/// takes one, or delivered once it is idle when it does not.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);
  final local = Platform.isWindows ? 'windowsNative' : 'localPosix';

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late ServerSessionLauncher launches;
  late DaemonAgentStatus status;
  late SessionQueueDao dao;
  late Directory temp;
  late List<String> delivered;
  var ids = 0;

  setUp(() {
    ids = 0;
    delivered = [];
    temp = Directory.systemTemp.createTempSync('queue_resume_test');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, ssh_host_id, '
      'created_at) VALUES (?, ?, ?, ?, ?);',
      ['local', local, 'Here', null, '$t0'],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the cart',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'conv-1',
      ),
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    final rows = CheckoutRows(database);
    launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
        now: () => t0,
        newId: () => 'new-${++ids}',
        environmentOf: rows.environment,
        settings: () =>
            LaunchSettings.parse(database.readMetadata('settings.v1')),
        hasUsableLogin: (_) async => false,
        vaultNames: () => const {},
        handoffs: SessionHandoffs(
          dao: SessionHandoffDao(database),
          root: Directory('${temp.path}${Platform.pathSeparator}handoff'),
          now: () => t0,
        ),
        links: SessionRepositoryDao(database),
        windows: false,
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      settings: () =>
          LaunchSettings.parse(database.readMetadata('settings.v1')),
      presenceOf: (_, _) async => ConversationPresence.unknown,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    dao = SessionQueueDao(database);
  });

  tearDown(() async {
    await status.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  SessionQueue queueOver({bool takesOpeningMessage = true}) {
    var n = 0;
    final queue = SessionQueue(
      dao: dao,
      status: status,
      resumeStopped: (sessionId, prompt) =>
          launches.resume(sessionId, prompt: prompt),
      takesOpeningMessage: (_) => takesOpeningMessage,
      newId: () => 'q${++n}',
      now: () => t0,
    )..deliver = ((_, text) async => delivered.add(text));
    addTearDown(queue.close);
    return queue..start();
  }

  /// The resumed agent draws its idle composer, and the server reads it.
  Future<void> showsIdle() async {
    final text = File(
      '../app/test/features/agents/fixtures/claude-code-tui.raw',
    ).readAsStringSync();
    final teardown = text.indexOf('Session terminated');
    pty.handles.last.emit(
      utf8.encode(teardown < 0 ? text : text.substring(0, teardown)),
    );
    await pumpEventQueue();
    status.tick();
    await pumpEventQueue();
  }

  void hook(String event) => status.hook(
    AgentHookEvent(
      agent: AgentIds.claudeCode,
      event: event,
      sessionHeader: 's1',
      receivedAt: DateTime.now().toUtc(),
      body: {'session_id': 'conv-1', 'hook_event_name': event},
    ),
  );

  QueuedMessage queued(String id, String text) => dao.enqueue(
    id: id,
    sessionId: 's1',
    text: text,
    origin: QueuedMessageOrigin.app,
    now: t0,
  );

  test('a session resumed by launches.resume takes its head once it is '
      'idle', () async {
    queued('old', 'earlier');
    queueOver();

    await launches.resume('s1');
    expect(delivered, isEmpty, reason: 'not idle yet');
    await showsIdle();

    expect(delivered, ['earlier']);
    expect(dao.getById('old')!.state, QueuedMessageState.delivered);
  });

  test('a send to a stopped session with messages waiting resumes it with '
      'the head as its opening prompt', () async {
    queued('old', 'earlier');
    final queue = queueOver();

    final later = queue.admit('s1', 'later', origin: QueuedMessageOrigin.app);
    expect(later, isA<AdmitQueued>());
    await pumpEventQueue();

    expect(pty.started, hasLength(1));
    expect(pty.started.single.argv.join(' '), contains('earlier'));
    expect(dao.getById('old')!.state, QueuedMessageState.delivered);
    expect(delivered, isEmpty);

    // The opening prompt's turn runs and ends: the next goes, one per turn.
    await showsIdle();
    hook('UserPromptSubmit');
    hook('Stop');
    await pumpEventQueue();
    expect(delivered, ['later']);
  });

  test('an agent that takes no opening prompt is resumed bare and given the '
      'head once idle', () async {
    queued('old', 'earlier');
    final queue = queueOver(takesOpeningMessage: false);

    queue.admit('s1', 'later', origin: QueuedMessageOrigin.app);
    await pumpEventQueue();

    expect(pty.started, hasLength(1));
    expect(pty.started.single.argv.join(' '), isNot(contains('earlier')));
    expect(dao.getById('old')!.state, QueuedMessageState.queued);
    expect(delivered, isEmpty);

    await showsIdle();
    expect(delivered, ['earlier']);
    expect(dao.getById('q1')!.state, QueuedMessageState.queued);
  });

  test('a resume answered by one already starting does not count the head '
      'as delivered: it waits and goes once idle', () async {
    queued('old', 'earlier');
    final queue = queueOver();

    // A boot's automatic continue is starting the session with its own
    // opening prompt when the person's send arrives.
    final continuing = launches.resume('s1', prompt: 'continue please');
    queue.admit('s1', 'later', origin: QueuedMessageOrigin.app);
    await continuing;
    await pumpEventQueue();

    expect(pty.started, hasLength(1));
    expect(pty.started.single.argv.join(' '), contains('continue please'));
    expect(pty.started.single.argv.join(' '), isNot(contains('earlier')));
    expect(
      dao.getById('old')!.state,
      QueuedMessageState.queued,
      reason: 'the opening prompt that went was not this message',
    );

    await showsIdle();
    expect(delivered, ['earlier']);
    expect(dao.getById('old')!.state, QueuedMessageState.delivered);
  });

  test('a resume that is refused fails the head in words rather than '
      'holding it forever', () async {
    queued('old', 'earlier');
    SessionDao(database).delete('s1');
    final queue = queueOver();
    queue.admit('s1', 'later', origin: QueuedMessageOrigin.app);
    await pumpEventQueue();

    final head = dao.getById('old')!;
    expect(head.state, QueuedMessageState.failed);
    expect(head.error, isNotEmpty);
    expect(pty.started, isEmpty);
  });

  group('a session started by any path, its reader silent', () {
    const quiet = Duration(milliseconds: 300);
    String? pausedStore;

    /// A queue told of every start, as `serve` tells it the lifecycle's.
    SessionQueue starting() {
      var n = 0;
      final queue = SessionQueue(
        dao: dao,
        status: status,
        quietPeriod: quiet,
        quietPoll: const Duration(milliseconds: 10),
        readPaused: () => pausedStore,
        writePaused: (value) => pausedStore = value,
        newId: () => 'q${++n}',
        now: () => t0,
      )..deliver = ((_, text) async => delivered.add(text));
      final opened = registry.changes.listen((change) {
        if (change is SessionOpened) {
          queue.hostSessionStarted(change.process.id);
        }
      });
      addTearDown(() async {
        await opened.cancel();
        await queue.close();
      });
      return queue..start();
    }

    Future<void> startUpScreen() async {
      pty.handles.last.emit(utf8.encode('› Ask Codex to do anything\r\n'));
      await pumpEventQueue();
    }

    setUp(() => pausedStore = null);

    test('takes its head once the start-up screen has been quiet', () async {
      queued('old', 'earlier');
      starting();

      await launches.resume('s1');
      await startUpScreen();
      expect(status.statusOf('s1'), isNull, reason: 'nothing reads it');
      expect(delivered, isEmpty);

      await Future<void>.delayed(quiet * 3);
      expect(delivered, ['earlier']);
    });

    test('waits while the start-up screen still moves', () async {
      queued('old', 'earlier');
      final queue = starting();

      await launches.resume('s1');
      for (var i = 0; i < 15; i++) {
        pty.handles.last.emit(utf8.encode('loading $i\r\n'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(delivered, isEmpty);
      expect(queue.busy('s1'), isTrue, reason: 'still starting');
    });

    test(
      'a pause survives a server restart and holds through a resume',
      () async {
        queued('old', 'earlier');
        final before = starting();
        before.pause('s1');
        expect(before.list('s1').single.hold?.kind, QueueHoldKind.paused);
        await before.close();

        final after = starting();
        expect(after.list('s1').single.hold?.kind, QueueHoldKind.paused);
        await launches.resume('s1');
        await startUpScreen();
        await Future<void>.delayed(quiet * 3);
        expect(delivered, isEmpty);
        expect(after.list('s1').single.hold?.kind, QueueHoldKind.paused);

        // Asking for the next one is the person going on.
        await after.sendNext('s1');
        await pumpEventQueue();
        expect(delivered, ['earlier']);
        expect(pausedStore, anyOf(isNull, '[]'));
      },
    );
  });
}
