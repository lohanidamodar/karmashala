import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/sessions/daemon_session_sync.dart';
import 'package:karmashala_host/src/sessions/pane_facts.dart';
import 'package:karmashala_host/src/sessions/pane_source.dart';
import 'package:karmashala_session/session.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';

import 'sync_fixture.dart';

/// The server's session sync as a whole (slice 2b): its passes — cheap
/// checks first, at most one store scan shared by adoption, launched
/// attribution and the title sync — the hooks it takes, the server's own
/// panes (slice 5c) and the tails it reads off them; and one pass end to end
/// over a real agent store in a temp folder, scanned on the worker isolate.
void main() {
  late SyncFixture world;
  late Directory tmp;
  late List<DetectedSession> store;
  late int scans;
  late _Panes panes;

  setUp(() {
    panes = _Panes();
    world = SyncFixture();
    tmp = Directory.systemTemp.createTempSync('karmashala_session_sync_');
    store = [];
    scans = 0;
  });
  tearDown(() {
    world.close();
    tmp.deleteSync(recursive: true);
  });

  DaemonSessionSync sync({
    Future<List<DetectedSession>> Function()? scan,
    Future<List<CliStore>> Function()? locateStores,
  }) => DaemonSessionSync(
    database: world.db,
    data: world.data,
    registry: SessionRegistry(launcher: FakePtyLauncher()),
    panes: panes,
    locateStores: locateStores ?? () async => const [],
    scan:
        scan ??
        () async {
          scans++;
          return List.of(store);
        },
    clock: MovableClock(launchedAt),
    newId: sequentialIds(),
    log: world.logs.add,
  );

  PaneFacts pane(
    String id, {
    String? commandId,
    String? commandLine,
    bool launched = false,
  }) => PaneFacts(
    paneId: id,
    workingDirectory: repoPath,
    live: true,
    hostsLaunchedSession: launched,
    lastCommandId: commandId,
    lastCommandLine: commandLine,
  );

  /// The server's panes are now [now]; the sync is told.
  void show(DaemonSessionSync subject, List<PaneFacts> now) {
    panes.all = now;
    subject.panesChanged();
  }

  AgentHookEvent hook(
    String agent,
    Map<String, Object?> body, {
    String? pane,
  }) => AgentHookEvent(
    agent: agent,
    event: 'UserPromptSubmit',
    receivedAt: launchedAt,
    body: body,
    sessionHeader: pane,
  );

  group('a pass', () {
    test('costs no scan while nothing waits', () async {
      world.insert(sessionRow(externalId: 'c1', titleByUser: true));
      final subject = sync();
      for (var i = 0; i < 20; i++) {
        await subject.pass();
      }
      expect(subject.passes, 20);
      expect(scans, 0);
      expect(world.told, isEmpty);
    });

    test('buys one scan for everything waiting, in the right order', () async {
      // A launched Codex row with no conversation, an armed pane, and a named
      // row: one scan answers all three. Attribution learns the id first, so
      // the title sync names the row in the same pass.
      world.insert(sessionRow(id: 'launched', installation: 'a2'));
      final subject = sync();
      show(subject, [pane('pane-1', commandId: 'c')]);
      show(subject, [pane('pane-1', commandId: 'c', commandLine: 'claude')]);
      store
        ..add(
          storeSession(
            'codex-1',
            cli: AgentIds.codex,
            title: 'Port the reader',
            startedAt: launchedAt.add(const Duration(seconds: 5)),
          ),
        )
        ..add(storeSession('cli-abc', modifiedAt: launchedAt));

      await subject.pass();

      expect(scans, 1);
      final launched = world.row('launched')!;
      expect(launched.externalSessionId, 'codex-1');
      expect(launched.title, 'Port the reader');
      final adopted = world.sessions.getAllByExternalSessionId('cli-abc');
      expect(adopted.single.paneId, 'pane-1');
    });

    test('a scan that fails writes nothing, and says so', () async {
      world.insert(sessionRow(installation: 'a2'));
      final subject = sync(scan: () async => throw StateError('share gone'));
      await subject.pass();
      expect(world.row('s1')!.externalSessionId, isNull);
      expect(world.told, isEmpty);
      expect(world.logs.single, contains('share gone'));
    });

    test('passes do not overlap', () async {
      world.insert(sessionRow(installation: 'a2'));
      final subject = sync();
      await Future.wait([subject.pass(), subject.pass(), subject.pass()]);
      expect(subject.passes, 1);
    });
  });

  group('hooks', () {
    test('claim the armed pane the hook came from', () {
      final subject = sync();
      show(subject, [pane('pane-1', commandId: 'c')]);
      show(subject, [pane('pane-1', commandId: 'c', commandLine: 'claude')]);

      subject.hook(
        hook(AgentIds.claudeCode, {'session_id': 'cli-abc', 'cwd': repoPath}),
      );

      final row = world.sessions.getAllByExternalSessionId('cli-abc').single;
      expect(row.paneId, 'pane-1');
      expect(world.toldRows, [row.id]);
    });

    test('read the agent\'s own fields: a list of workspaces for agy', () {
      final subject = sync();
      show(subject, [pane('pane-1', commandId: 'c')]);
      show(subject, [pane('pane-1', commandId: 'c', commandLine: 'agy')]);

      subject.hook(
        hook(AgentIds.antigravity, {
          'conversationId': 'agy-1',
          'workspacePaths': [repoPath],
        }),
      );

      final row = world.sessions.getAllByExternalSessionId('agy-1').single;
      expect(row.paneId, 'pane-1');
      expect(row.workingDirectory?.path, repoPath);
      expect(row.agentInstallationId, 'a3');
    });

    test('from a pane that runs a row of ours are that row\'s', () {
      world.insert(sessionRow(id: 'mine'));
      final subject = sync();
      show(subject, [pane('pane-1', commandId: 'c')]);
      show(subject, [pane('pane-1', commandId: 'c', commandLine: 'claude')]);

      subject.hook(
        hook(AgentIds.claudeCode, {'session_id': 'cli-abc'}, pane: 'mine'),
      );

      expect(world.sessions.getAllByExternalSessionId('cli-abc'), isEmpty);
    });

    test('of an agent nobody knows, or out of shape, change nothing', () {
      final subject = sync();
      subject.hook(hook('nobody', {'session_id': 'x'}));
      subject.hook(hook(AgentIds.claudeCode, {'session_id': 42}));
      expect(world.told, isEmpty);
    });
  });

  group('the server\'s panes', () {
    test('a pane that goes takes its arming with it', () {
      final subject = sync();
      show(subject, [pane('pane-1', commandId: 'c')]);
      show(subject, [pane('pane-1', commandId: 'c', commandLine: 'claude')]);
      expect(subject.adoption.armedPaneIds, ['pane-1']);

      show(subject, const []);

      expect(subject.adoption.armedPaneIds, isEmpty);
      subject.hook(hook(AgentIds.claudeCode, {'session_id': 'cli-abc'}));
      expect(world.told, isEmpty);
    });

    test('are read for tails only where a screen could arm one', () async {
      final subject = sync();
      show(subject, [
        pane('idle'),
        pane('armed', commandId: 'c'),
        pane('launched', launched: true),
      ]);
      show(subject, [
        pane('idle'),
        pane('armed', commandId: 'c', commandLine: 'claude'),
        pane('launched', launched: true),
      ]);

      await subject.pass();

      expect(panes.read, [('idle', subject.adoption.screenLines)]);
    });

    test(
      'a screen read off the pane arms it where its shell could not',
      () async {
        final subject = sync();
        show(subject, [pane('pane-1')]);
        await subject.pass();
        expect(subject.adoption.armedPaneIds, isEmpty);

        panes.tails['pane-1'] = [
          '',
          '  ? for shortcuts · shift+tab to cycle  ',
        ];
        store.add(storeSession('cli-abc', modifiedAt: launchedAt));
        await subject.pass();

        final row = world.sessions.getAllByExternalSessionId('cli-abc').single;
        expect(row.paneId, 'pane-1');
        expect(subject.adoption.gridReads, 1);
      },
    );

    test(
      'a launched pane reported live keeps its row\'s title followed',
      () async {
        world.insert(
          sessionRow(
            externalId: 'c1',
            title: 'karmashala revisits',
            paneId: 'pane-1',
            status: SessionStatus.completed,
          ),
        );
        store.add(storeSession('c1', title: 'karmashala enhanced'));
        final subject = sync();
        await subject.pass();
        expect(world.row('s1')!.title, 'karmashala revisits');

        show(subject, [pane('pane-1', launched: true)]);
        await subject.pass();
        expect(world.row('s1')!.title, 'karmashala enhanced');
      },
    );
  });

  group('directory attribution reads the server\'s pane', () {
    late String agyHome;
    const conversation = 'df3c0708-1111-4222-8333-444455556666';

    setUp(() {
      agyHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
      File(p.join(agyHome, 'cache', 'last_conversations.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({r'C:\elsewhere': 'nobody'}));
    });

    test('asking for the row\'s pane, and reading the line printed', () async {
      world.insert(sessionRow(installation: 'a3', paneId: 'pane-1'));
      final subject = sync(
        locateStores: () async => [
          CliStore(
            environmentId: 'windows',
            homesByAgentId: {AgentIds.antigravity: agyHome},
          ),
        ],
      );
      show(subject, [pane('pane-1', launched: true)]);

      await subject.pass();
      expect(world.row('s1')!.externalSessionId, isNull);
      expect(panes.read.map((read) => read.$1), contains('pane-1'));

      panes.tails['pane-1'] = [
        'Resume with -c (or command below):',
        'agy --conversation=$conversation',
      ];
      await subject.pass();

      expect(world.row('s1')!.externalSessionId, conversation);
      expect(world.toldRows, ['s1']);
    });
  });

  group('end to end over real stores in a temp home, scanned on the worker '
      'isolate', () {
    late String codexHome;
    late String agyHome;
    const conversation = '01a05c73-912d-7bf3-84cc-a1bb591134aa';
    const agyConversation = 'df3c0708-1111-4222-8333-444455556666';
    const threadName = "hey let's work on karmashala app, i";

    setUp(() {
      codexHome = p.join(tmp.path, '.codex');
      agyHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
    });

    /// One rollout in the shape Codex 0.151 writes it, and — when [name] is
    /// given — the thread's name, which Codex writes only once it has one.
    void writeRollout({
      Duration startedAfterLaunch = const Duration(seconds: 5),
      String? name = threadName,
    }) {
      final startedAt = launchedAt.add(startedAfterLaunch);
      File(
          p.join(
            codexHome,
            'sessions',
            '2026',
            '09',
            '01',
            'rollout-$conversation.jsonl',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${jsonEncode({
            'timestamp': startedAt.add(const Duration(seconds: 30)).toIso8601String(),
            'type': 'session_meta',
            'payload': {'id': conversation, 'session_id': conversation, 'timestamp': startedAt.toIso8601String(), 'cwd': repoPath, 'originator': 'codex-tui'},
          })}\n'
          '${jsonEncode({
            'timestamp': startedAt.toIso8601String(),
            'type': 'response_item',
            'payload': {
              'type': 'message',
              'role': 'user',
              'content': [
                {'type': 'input_text', 'text': 'hey lets work on karmashala app'},
              ],
            },
          })}\n',
        );
      if (name == null) return;
      File(p.join(codexHome, 'session_index.jsonl')).writeAsStringSync(
        '${jsonEncode({'id': conversation, 'thread_name': name})}\n',
      );
    }

    /// An `agy` store: the conversation's database, the directory's last
    /// conversation, and — when [title] is given — `/rename`'s annotation.
    void writeAgyStore({String? title}) {
      final database = p.join(agyHome, 'conversations', '$agyConversation.db');
      Directory(p.dirname(database)).createSync(recursive: true);
      sqlite3.open(database)
        ..execute(
          'CREATE TABLE `steps` (`idx` integer, `step_type` integer NOT NULL '
          'DEFAULT 0, `status` integer NOT NULL DEFAULT 0);',
        )
        ..close();
      File(
        database,
      ).setLastModifiedSync(launchedAt.add(const Duration(seconds: 5)));
      File(p.join(agyHome, 'cache', 'last_conversations.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({repoPath: agyConversation}));
      if (title == null) return;
      File(p.join(agyHome, 'annotations', '$agyConversation.pbtxt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('title:"$title"\n');
    }

    DaemonSessionSync real() {
      final subject = DaemonSessionSync(
        database: world.db,
        data: world.data,
        registry: SessionRegistry(launcher: FakePtyLauncher()),
        locateStores: () async => [
          CliStore(
            environmentId: 'windows',
            homesByAgentId: {
              AgentIds.codex: codexHome,
              AgentIds.antigravity: agyHome,
            },
          ),
        ],
        log: world.logs.add,
      );
      addTearDown(subject.close);
      return subject;
    }

    test('a launched Codex row learns its conversation and its name', () async {
      writeRollout();
      world.insert(sessionRow(installation: 'a2', paneId: 'pane-1'));
      final subject = real();

      await subject.pass();

      final row = world.row('s1')!;
      expect(row.externalSessionId, conversation);
      expect(row.title, threadName);
      expect(subject.scans, 1);
      expect(world.logs, isEmpty);
      expect(world.toldRows.toSet(), {'s1'});
    });

    test(
      'a conversation nobody named leaves the row its placeholder',
      () async {
        writeRollout(name: null);
        world.insert(sessionRow(installation: 'a2'));
        await real().pass();
        expect(world.row('s1')!.externalSessionId, conversation);
        expect(world.row('s1')!.title, 'New session');
      },
    );

    test(
      'a conversation from before the launch is left where it was',
      () async {
        writeRollout(startedAfterLaunch: const Duration(hours: -1));
        world.insert(sessionRow(installation: 'a2'));
        await real().pass();
        expect(world.row('s1')!.externalSessionId, isNull);
      },
    );

    test('a name typed into agy reaches the row', () async {
      writeAgyStore(title: 'test me now');
      world.insert(sessionRow(installation: 'a3', externalId: agyConversation));
      await real().pass();
      expect(world.row('s1')!.title, 'test me now');
    });

    test('a phantom agy row learns its id and its name in one pass', () async {
      writeAgyStore(title: 'test me now');
      world.insert(sessionRow(installation: 'a3'));
      await real().pass();
      final row = world.row('s1')!;
      expect(row.externalSessionId, agyConversation);
      expect(row.title, 'test me now');
    });

    test('with no annotation the agy row keeps the name it had', () async {
      writeAgyStore();
      world.insert(sessionRow(installation: 'a3', externalId: agyConversation));
      await real().pass();
      expect(world.row('s1')!.title, 'New session');
    });
  });
}

/// The server's panes as a test sets them, and the tails the sync reads.
class _Panes implements PaneSource {
  @override
  List<PaneFacts> all = const [];

  final tails = <String, List<String>>{};
  final read = <(String, int)>[];

  @override
  List<String>? tailOf(String paneId, int lines) {
    read.add((paneId, lines));
    return tails[paneId];
  }
}
