import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/discovery.dart' show AgentInstallation, SystemClock;
import 'package:agent_cli/process.dart' show ExecutionEnvironment;
import 'package:agent_cli/read.dart' show CliStoreLocator;
import 'package:agent_cli/usage.dart'
    show AgentUsage, AgentUsageService, UsageWindow;
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// The phone companion served by the daemon, end to end: a real companion
/// client dials the daemon's LAN listener, seals with the key a pairing row
/// holds, and asks what a phone asks. Nothing between the two ends is stubbed
/// but the PTY.
void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 7));

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late StreamController<LifecycleEvent> events;
  late DaemonCompanion companion;
  late Directory home;
  late _FakeUsage usage;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('daemon-companion-');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    // This machine, a WSL beside it, and Claude Code installed here — the
    // rows agent discovery leaves.
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?), (?, ?, ?, ?);',
      [
        'local', 'localPosix', 'This Mac', t0.toIso8601String(), //
        'wsl1', 'wsl', 'Ubuntu', t0.toIso8601String(),
      ],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, version, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      [
        'a1', 'claudeCode', 'local', '/usr/bin/claude', '2.1.283', //
        t0.toIso8601String(), 1,
      ],
    );
    database.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      'created_at) VALUES (?, ?, ?, ?, ?);',
      ['p1', 'Shop', 'local', '/src/shop', t0.toIso8601String()],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', t0.toIso8601String()],
    );
    PairedDeviceDao(database).insert(
      PairedDevice(
        id: 'pixel',
        name: 'Pixel',
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        generation: 0,
        createdAt: t0,
      ),
    );
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    events = StreamController<LifecycleEvent>.broadcast();
    usage = _FakeUsage();
    companion = DaemonCompanion(
      database: database,
      registry: registry,
      hostName: 'desk',
      dataDirectory: '${home.path}/data',
      lanPort: 0,
      transcriptPollInterval: Duration.zero,
      screens: RegistryScreens(registry, enterDelay: Duration.zero),
      clock: () => t0,
      windows: false,
      usageService: usage,
      hostEnvironment: {'HOME': home.path, 'USERPROFILE': home.path},
    );
    await companion.start(sessionEvents: events.stream);
  });

  tearDown(() async {
    await companion.close();
    await events.close();
    // A fake child never exits on its own; the shutdown would wait out its
    // reap bound for each.
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    home.deleteSync(recursive: true);
  });

  void insertRow(
    String id, {
    String title = 'Fix the cart',
    SessionStatus? status,
  }) => SessionDao(database).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: title,
      useWorktree: false,
      status: status ?? SessionStatus.running,
      createdAt: t0,
    ),
  );

  FakePtyHandle openHosted(
    String hostId, {
    List<String> argv = const ['claude'],
  }) {
    registry.open(
      hostId,
      PtySpawnRequest(
        argv: argv,
        workingDirectory: '/src/shop/api',
        environment: const {},
        columns: 80,
        rows: 24,
      ),
    );
    return launcher.handles.last;
  }

  Future<CompanionClient> dial() async {
    final port = companion.port!;
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: hostDeviceIdFor(database),
        deviceId: DeviceId.parse('c' * 32),
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        relay: Uri.parse('https://unused.invalid'),
        generation: 0,
        hostName: 'desk',
        directEndpoint: '127.0.0.1:$port',
      ),
      store: InMemoryCompanionStore(),
    );
    addTearDown(client.close);
    await client.connect(
      transport: LanTransport(host: '127.0.0.1', port: port)..start(),
      generation: 0,
      helloTimeout: const Duration(seconds: 10),
    );
    return client;
  }

  group('with the desktop app closed', () {
    test(
      'a phone lists the store\'s rows and the sessions the host runs',
      () async {
        insertRow('s1');
        openHosted(hostSessionIdOf('s1'));
        openHosted('box_session', argv: const ['htop']);

        final client = await dial();
        final sessions = await client.listSessions();

        final row = sessions.singleWhere((s) => s.sessionId == 's1');
        expect(row.title, 'Fix the cart');
        expect(row.status, 'running');
        expect(row.repositoryName, 'shop-api');
        expect(row.projectName, 'Shop');
        expect(row.whereabouts, 'running on desk');
        expect(
          row.attention,
          isNull,
          reason: 'attention is the app\'s status registry; the host says none',
        );
        final box = sessions.singleWhere((s) => s.sessionId == 'box_session');
        expect(
          box.title,
          'htop',
          reason: 'a session no row names is its command',
        );
        expect(
          sessions,
          hasLength(2),
          reason: 'the row\'s own session is not listed twice',
        );
      },
    );

    test('a hosted session\'s transcript is its screen', () async {
      insertRow('s1');
      final pty = openHosted(hostSessionIdOf('s1'));
      pty.emit(utf8.encode('Claude is thinking\r\n> '));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final client = await dial();
      final page = await client.transcript('s1');

      expect(page.messages, hasLength(1));
      expect(page.messages.single.role, 'agent');
      expect(page.messages.single.text, 'Claude is thinking\n>');
    });

    test(
      'a session the host holds no screen for says there is no chat view',
      () async {
        insertRow('gone', status: SessionStatus.completed);

        final client = await dial();
        final page = await client.transcript('gone');

        expect(page.messages, isEmpty);
        expect(page.absence, RemoteTranscriptAbsence.noChatView);
      },
    );

    test('a prompt is typed into the hosted session, then Enter', () async {
      insertRow('s1');
      // Nobody holds the write token: the app's pane hung up with the app.
      final pty = openHosted(hostSessionIdOf('s1'));

      final client = await dial();
      final delivery = await client.sendPrompt('s1', 'run the tests');

      expect(delivery, RemotePromptDelivery.sent);
      expect(
        [for (final write in pty.writes) utf8.decode(write)],
        ['run the tests', '\r'],
      );
      expect(
        registry.find(hostSessionIdOf('s1'))!.token.isHeld,
        isFalse,
        reason: 'the token is let go, so a pane that attaches can drive',
      );
    });

    test(
      'a prompt to a session somebody is driving is refused by name',
      () async {
        insertRow('s1');
        openHosted(hostSessionIdOf('s1'));
        registry.find(hostSessionIdOf('s1'))!.token.claim('laptop-pane', t0);

        final client = await dial();

        await expectLater(
          client.sendPrompt('s1', 'hello'),
          throwsA(
            isA<RemoteApiException>().having(
              (e) => e.message,
              'message',
              contains('laptop-pane'),
            ),
          ),
        );
      },
    );

    test('notes and todos come from the store', () async {
      NoteDao(database).insert(
        Note(
          id: 'n1',
          body: 'Try a compact tab strip',
          projectId: 'p1',
          createdAt: t0,
          updatedAt: t0,
        ),
      );
      TodoDao(database).insert(
        Todo(id: 't1', body: 'Ship the fix', position: 0, createdAt: t0),
      );

      final client = await dial();
      final notes = await client.notes();

      expect(notes.notesEnabled, isTrue);
      expect(notes.notes.single.body, 'Try a compact tab strip');
      expect(notes.notes.single.projectName, 'Shop');
      expect(notes.todos.single.body, 'Ship the fix');
    });

    test(
      'the app arriving and leaving mid-sweep fails the sweep quietly',
      () async {
        insertRow('s1');
        final client = await dial();
        // A request makes the phone live, so the app's arrival re-sweeps it.
        await client.listSessions();

        final app = Object();
        final calls = <CompanionCallMessage>[];
        await companion.adopt(
          app,
          const CompanionConfig(enabled: true).toJson(),
          (message) {
            if (message is CompanionCallMessage) calls.add(message);
          },
        );
        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(calls.single.method, CompanionMethod.listSessions.wire);

        // Unanswered, then gone: the sweep's call fails. Escaping, that error
        // is uncaught — which fails this test, and in the daemon ends the
        // process with every session it holds.
        await companion.detach(app);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final after = await client.listSessions();
        expect(after.single.sessionId, 's1', reason: 'from the store again');
      },
    );

    test('a push token is kept in the store', () async {
      final client = await dial();
      await client.registerNotifications(token: 'fcm-1', platform: 'android');

      expect(PairedDeviceDao(database).getById('pixel')!.pushToken, 'fcm-1');
    });
  });

  // A machine with no desktop at all: everything a phone needs to drive it is
  // the daemon's own answer, from the store, the agents' adapters and PTYs it
  // holds. No app link exists in any of these tests.
  group('a phone driving a machine with no desktop', () {
    Matcher refused(Object message) => throwsA(
      isA<RemoteApiException>().having((e) => e.message, 'message', message),
    );

    void serveSessions() => companion.serveSessions(
      mcp: SessionMcpAccessPoint(
        mcp: null,
        configDirectory: '${home.path}/data/mcp',
      ),
    );

    void insertProject(String id, String name, String env, String root) {
      database.execute(
        'INSERT INTO projects (id, name, root_environment_id, root_path, '
        'created_at) VALUES (?, ?, ?, ?, ?);',
        [id, name, env, root, t0.toIso8601String()],
      );
    }

    void insertRepository(String id, String project, String env, String path) {
      database.execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, '
        'path, created_at) VALUES (?, ?, ?, ?, ?, ?);',
        [id, project, path.split('/').last, env, path, t0.toIso8601String()],
      );
    }

    Future<RemoteAgentOption> claudeHere(CompanionClient client) async =>
        (await client.listWorkspace())
            .singleWhere((p) => p.projectId == 'p1')
            .checkouts
            .single
            .agents
            .single;

    test(
      'the workspace is the store\'s, with the agents installed here',
      () async {
        // A project that lives in WSL: nothing here can start in it.
        insertProject('p2', 'Tools', 'wsl1', '/home/me/tools');
        insertRepository('r2', 'p2', 'wsl1', '/home/me/tools');

        final client = await dial();
        final workspace = await client.listWorkspace();

        expect(workspace.map((p) => p.name), ['Shop']);
        final checkout = workspace.single.checkouts.single;
        expect(checkout.repositoryId, 'r1');
        expect(checkout.name, 'shop-api');
        expect(checkout.subPath, 'api');
        expect(checkout.environmentName, isNotNull);
        expect(
          checkout.folderMissing,
          isTrue,
          reason: '/src/shop/api is not on this disk, and the host looked',
        );
        final agent = checkout.agents.single;
        expect(agent.installationId, 'a1');
        expect(agent.name, 'Claude Code');
        expect(agent.version, '2.1.283');
        expect(agent.acceptsOpeningMessage, isTrue);
        expect(
          agent.permissionModes.map((m) => m.mode),
          contains(agent.defaultMode),
          reason: 'the agent\'s declared default, offered and preselected',
        );

        final places = await client.listProjects();
        expect(places.map((p) => p.name), unorderedEquals(['Shop', 'Tools']));
      },
    );

    test('a folder added from the phone is a project of the repositories '
        'found under it', () async {
      final folder = Directory('${home.path}/work')..createSync();
      Directory('${folder.path}/app/.git').createSync(recursive: true);
      Directory('${folder.path}/lib').createSync();
      File('${folder.path}/lib/.git').writeAsStringSync('gitdir: ../x');
      Directory(
        '${folder.path}/node_modules/dep/.git',
      ).createSync(recursive: true);

      final client = await dial();
      final added = await client.addProject(
        requestId: 'add-1',
        name: 'Work',
        path: folder.path,
      );

      expect(added.name, 'Work');
      expect(added.checkouts.map((c) => c.name), ['app', 'lib']);
      expect(added.checkouts.first.agents.single.installationId, 'a1');
      expect(
        (await client.listWorkspace()).map((p) => p.name),
        containsAll(['Shop', 'Work']),
        reason: 'written to the store the app reads',
      );
      final again = await client.addProject(
        requestId: 'add-2',
        name: 'Work again',
        path: '${folder.path}/',
      );
      expect(
        again.projectId,
        added.projectId,
        reason: 'one folder, one project',
      );
    });

    test('a plain folder is its own checkout', () async {
      final folder = Directory('${home.path}/notes')..createSync();

      final client = await dial();
      final added = await client.addProject(
        requestId: 'add-plain',
        name: 'Notes',
        path: folder.path,
      );

      expect(added.checkouts.single.name, 'Notes');
      expect(added.checkouts.single.path, folder.resolveSymbolicLinksSync());
    });

    test('a path that is not a folder here is refused in words', () async {
      File('${home.path}/a-file').writeAsStringSync('x');
      final client = await dial();

      await expectLater(
        client.addProject(
          requestId: 'x1',
          name: 'Gone',
          path: '${home.path}/missing',
        ),
        refused('there is no folder at that path on this machine'),
      );
      await expectLater(
        client.addProject(
          requestId: 'x2',
          name: 'File',
          path: '${home.path}/a-file',
        ),
        refused('that path is a file, not a folder'),
      );
      await expectLater(
        client.addProject(requestId: 'x3', name: 'Rel', path: 'src/app'),
        refused(contains('absolute path')),
      );
    });

    test('a session starts here as the host\'s own, the agent chosen by its '
        'adapter', () async {
      final client = await dial();
      final agent = await claudeHere(client);

      await expectLater(
        client.startSession(
          requestId: 'early',
          repositoryId: 'r1',
          installationId: 'a1',
          permissionMode: agent.defaultMode,
        ),
        refused(kCompanionAppNotRunning),
        reason: 'nothing can hand an agent its tools before MCP is up',
      );
      serveSessions();

      final started = await client.startSession(
        requestId: 'start-1',
        repositoryId: 'r1',
        installationId: 'a1',
        permissionMode: agent.defaultMode,
        title: 'Fix the cart',
        message: 'run the tests',
      );

      final row = SessionDao(database).getById(started.sessionId)!;
      expect(row.title, 'Fix the cart');
      expect(row.status, SessionStatus.running);
      expect(row.permissionMode, agent.defaultMode);
      expect(started.permissionMode, agent.defaultMode);
      expect(
        row.externalSessionId,
        row.id,
        reason: 'Claude Code takes the id Karmashala gives it',
      );
      final spawn = launcher.started.last;
      expect(spawn.argv.first, '/usr/bin/claude');
      expect(spawn.argv, containsAllInOrder([row.id, 'run the tests']));
      expect(spawn.workingDirectory, '/src/shop/api');
      expect(spawn.environment[kSessionIdEnvironmentVariable], row.id);
      expect(registry.find(hostSessionIdOf(row.id)), isNotNull);
      expect(
        (await client.listSessions())
            .singleWhere((s) => s.sessionId == row.id)
            .status,
        'running',
      );
    });

    test('a start the agent or the checkout cannot take is refused', () async {
      database.execute(
        'INSERT INTO agent_installations (id, agent_kind, environment_id, '
        'executable_path, created_at, executable_by_user) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [
          'a2',
          'claudeCode',
          'wsl1',
          '/usr/bin/claude',
          t0.toIso8601String(),
          1,
        ],
      );
      serveSessions();
      final client = await dial();
      final agent = await claudeHere(client);

      await expectLater(
        client.startSession(
          requestId: 's-mode',
          repositoryId: 'r1',
          installationId: 'a1',
          permissionMode: 'no-such-mode',
        ),
        refused(contains('has no permission mode called "no-such-mode"')),
      );
      await expectLater(
        client.startSession(
          requestId: 's-env',
          repositoryId: 'r1',
          installationId: 'a2',
          permissionMode: agent.defaultMode,
        ),
        refused('Claude Code is not installed where that checkout lives'),
      );
      expect(launcher.started, isEmpty);
    });

    test('a session asked for in a worktree of its own runs there', () async {
      final repo = Directory('${home.path}/repo')..createSync();
      Future<void> git(List<String> args) async {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: repo.path,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await git(['init', '-q']);
      await git([
        '-c', 'user.name=t', '-c', 'user.email=t@example.com', //
        'commit', '-q', '--allow-empty', '-m', 'start',
      ]);
      insertProject('p3', 'Repo', 'local', repo.path);
      insertRepository('r3', 'p3', 'local', repo.path);
      serveSessions();
      final client = await dial();
      final agent = await claudeHere(client);

      final started = await client.startSession(
        requestId: 'wt-1',
        repositoryId: 'r3',
        installationId: 'a1',
        permissionMode: agent.defaultMode,
        worktree: true,
      );

      final row = SessionDao(database).getById(started.sessionId)!;
      final tree = row.worktree!.path;
      expect(row.useWorktree, isTrue);
      expect(Directory(tree).existsSync(), isTrue);
      expect(launcher.started.last.workingDirectory, tree);
      final branches = await Process.run('git', [
        'branch',
        '--list',
        sessionBranchName(row.id),
      ], workingDirectory: repo.path);
      expect('${branches.stdout}', contains(sessionBranchName(row.id)));
    });

    test('an ended session resumes in a new hosted PTY, and only when its '
        'agent kept the conversation', () async {
      SessionDao(database).insert(
        Session(
          id: 'ended',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Yesterday',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: t0,
          externalSessionId: 'conv-1',
        ),
      );
      final bucket = Directory('${home.path}/.claude/projects/-src-shop-api')
        ..createSync(recursive: true);
      serveSessions();
      final client = await dial();

      await expectLater(
        client.resumeSession(requestId: 'r-1', sessionId: 'ended'),
        refused(contains('has no record of this conversation')),
        reason: 'the store was read to the end without it',
      );
      expect(launcher.started, isEmpty);
      expect(
        SessionDao(database).getById('ended')!.status,
        SessionStatus.completed,
      );

      File('${bucket.path}/conv-1.jsonl').writeAsStringSync('{}\n');
      final resumed = await client.resumeSession(
        requestId: 'r-2',
        sessionId: 'ended',
      );

      expect(resumed.sessionId, 'ended', reason: 'the same row, continued');
      expect(
        launcher.started.single.argv,
        containsAllInOrder(['--resume', 'conv-1']),
      );
      expect(launcher.started.single.argv, isNot(contains('--session-id')));
      expect(
        SessionDao(database).getById('ended')!.status,
        SessionStatus.running,
      );
      expect(registry.find(hostSessionIdOf('ended')), isNotNull);

      final again = await client.resumeSession(
        requestId: 'r-3',
        sessionId: 'ended',
      );
      expect(again.sessionId, 'ended');
      expect(
        launcher.started,
        hasLength(1),
        reason: 'still running here: that is the session, no second process',
      );
    });

    test('a session with no conversation to resume says so', () async {
      insertRow('fresh', status: SessionStatus.failed);
      serveSessions();
      final client = await dial();

      await expectLater(
        client.resumeSession(requestId: 'r-x', sessionId: 'fresh'),
        refused('this session has no conversation to resume'),
      );
    });

    test('a session\'s models and modes come from its adapter, and a change '
        'is recorded', () async {
      insertRow('s1', status: SessionStatus.completed);
      serveSessions();
      final client = await dial();
      final agent = await claudeHere(client);

      final options = await client.sessionOptions('s1');
      expect(options.models, isNotEmpty);
      expect(options.permissions, isNotEmpty);
      expect(options.permissionDefaultLabel, isNotNull);
      final dangerous = agent.permissionModes.firstWhere((m) => m.dangerous);
      expect(
        options.permissions.map((c) => c.id),
        isNot(contains(dangerous.mode)),
      );

      final model = options.models.first.id;
      expect(
        await client.configureSession('s1', modelId: model),
        RemoteConfigureOutcome.recorded,
        reason: 'nothing running to move; the next resume starts on it',
      );
      expect(SessionDao(database).getById('s1')!.modelId, model);
      final safe = options.permissions.last.id;
      await client.configureSession('s1', permissionId: safe);
      expect(SessionDao(database).getById('s1')!.permissionMode, safe);
      await expectLater(
        client.configureSession('s1', permissionId: dangerous.mode),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.code,
            'code',
            ErrorCode.notPermitted,
          ),
        ),
      );
    });

    test('usage is read through each adapter\'s usage capability', () async {
      final client = await dial();
      final snapshot = await client.usage();

      final account = snapshot.accounts.single;
      expect(account.agentName, 'Claude Code');
      expect(account.email, 'owner@example.com');
      expect(account.windows.single.label, '5-hour');
      expect(account.windows.single.percent, 42);
      expect(usage.asked, ['a1']);
    });

    test(
      'a file sent from the phone is kept here and handed over by path',
      () async {
        insertRow('s1');
        final pty = openHosted(hostSessionIdOf('s1'));
        final client = await dial();

        final row = (await client.listSessions()).singleWhere(
          (s) => s.sessionId == 's1',
        );
        expect(row.attachments!.allowsAnything, isTrue);
        expect(row.attachments!.mediaTypes, contains('image/png'));

        final offer = await client.beginAttachment(
          const RemoteAttachmentBegin(
            sessionId: 's1',
            name: 'screen shot.png',
            mediaType: 'image/png',
            bytes: 4,
          ),
        );
        await client.sendAttachmentChunk(offer.uploadId, 0, [1, 2, 3, 4]);
        final delivery = await client.sendPrompt(
          's1',
          'what is wrong here?',
          attachmentId: offer.uploadId,
        );

        expect(delivery, RemotePromptDelivery.sent);
        final typed = utf8.decode(pty.writes.first);
        final path = typed.split('\n').last;
        expect(
          typed,
          startsWith('what is wrong here?\n\nAttached image(s):\n'),
        );
        expect(path, startsWith('${home.path}/data/attachments/'));
        expect(path, endsWith('.png'));
        expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
        expect(utf8.decode(pty.writes.last), '\r');
      },
    );
  });

  group('with the desktop app connected', () {
    final app = Object();
    late List<CompanionCallMessage> calls;

    setUp(() async {
      calls = [];
      await companion.adopt(
        app,
        const CompanionConfig(enabled: true).toJson(),
        (message) {
          if (message is CompanionCallMessage) calls.add(message);
        },
      );
    });

    test('the session list is the app\'s', () async {
      insertRow('s1');
      final client = await dial();
      final listing = client.listSessions();
      while (calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final call = calls.first;
      expect(call.method, CompanionMethod.listSessions.wire);
      companion.answer(
        app,
        CompanionResultMessage.success(call.callId, {
          'sessions': [
            const RemoteSessionSnapshot(
              sessionId: 's1',
              title: 'Fix the cart',
              status: 'running',
              attention: kAttentionNeedsApproval,
            ).toJson(),
          ],
        }),
      );
      // The stage of each row is asked of the app too.
      while (calls.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      companion.answer(
        app,
        CompanionResultMessage.success(calls[1].callId, {'stage': null}),
      );

      final sessions = await listing;
      expect(sessions.single.attention, kAttentionNeedsApproval);
    });

    test('an app refusal reaches the phone in the app\'s words', () async {
      final client = await dial();
      final listing = client.listProjects();
      while (calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      companion.answer(
        app,
        CompanionResultMessage.failure(
          calls.first.callId,
          code: ErrorCode.badRequest.wire,
          message: 'no projects here',
        ),
      );

      await expectLater(
        listing,
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.message,
            'message',
            'no projects here',
          ),
        ),
      );
    });

    test(
      'news from the app returns before the app answers what it asks',
      () async {
        final client = await dial();
        // A phone that listed sessions, and so is swept for new ones.
        final listing = client.listSessions();
        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        companion.answer(
          app,
          CompanionResultMessage.success(calls.first.callId, {'sessions': []}),
        );
        await listing;
        calls.clear();

        // The host server reads the app's next frame — the answer the re-sweep
        // waits for — only once this returns; awaiting the sweep here is a
        // link that never reads again.
        await companion
            .notice(
              app,
              const CompanionNoticeMessage(CompanionNoticeKind.sessionsMoved),
            )
            .timeout(const Duration(seconds: 2));

        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(calls.first.method, CompanionMethod.listSessions.wire);
        companion.answer(
          app,
          CompanionResultMessage.success(calls.first.callId, {'sessions': []}),
        );
      },
    );

    test(
      'the app leaving mid-call fails that call, and the host answers after',
      () async {
        insertRow('s1');
        final client = await dial();
        final listing = client.listSessions();
        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        await companion.detach(app);

        await expectLater(listing, throwsA(isA<RemoteApiException>()));
        final after = await client.listSessions();
        expect(after.single.sessionId, 's1', reason: 'from the store now');
      },
    );
  });

  group('settings', () {
    test('what the app sent is kept, without its own relay', () async {
      await companion.adopt(
        Object(),
        CompanionConfig(
          enabled: true,
          relay: Uri.parse('wss://relay.example.com'),
          localRelayUrl: Uri.parse('ws://192.168.1.4:8787'),
          notesEnabled: false,
        ).toJson(),
        (_) {},
      );

      final kept = CompanionConfigStore(database).read()!;
      expect(kept.relay, Uri.parse('wss://relay.example.com'));
      expect(kept.localRelayUrl, isNull);
      expect(kept.notesEnabled, isFalse);
    });

    test('remote access switched off stops listening', () async {
      expect(companion.service, isNotNull);

      await companion.adopt(
        Object(),
        const CompanionConfig(enabled: false).toJson(),
        (_) {},
      );

      expect(companion.service, isNull);
      expect(companion.port, isNull);
    });

    test('a pairing with no relay anywhere is direct and says so', () async {
      final window = await companion.openPairing(
        capabilities: CapabilitySet.all.bits,
        relay: '',
        relayIsLocal: false,
      );

      expect(window.code, isNotEmpty);
      expect(window.payload, isNotEmpty);
      final ended = expectLater(window.paired, throwsA(anything));
      await companion.notice(
        Object(),
        const CompanionNoticeMessage(CompanionNoticeKind.pairingCancelled),
      );
      await ended;
    });
  });
}

/// The usage endpoint, stood in for: one reading per installation asked,
/// recorded so a test can see which agents were read.
class _FakeUsage extends AgentUsageService {
  _FakeUsage()
    : super(
        storeLocator: CliStoreLocator(
          runnerFor: (_) => throw UnimplementedError(),
        ),
        clock: const SystemClock(),
      );

  final asked = <String>[];

  @override
  Future<AgentUsage> fetch(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    asked.add(installation.id);
    return AgentUsage(
      windows: const [UsageWindow(label: '5-hour', percent: 42)],
      fetchedAt: DateTime.utc(2026, 9, 25, 11, 59),
      email: 'owner@example.com',
    );
  }
}
