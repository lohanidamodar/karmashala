import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/read.dart' show ConversationPresence;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/src/sessions/launch/handoff_packet_files.dart';
import 'package:karmashala_host/src/sessions/launch/launch_settings.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
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

/// A child that exits when it is signalled, as a real one does.
class _DyingLauncher implements PtyLauncher {
  final started = <PtySpawnRequest>[];
  final handles = <_DyingHandle>[];
  var _pid = 1000;

  @override
  PtyHandle start(PtySpawnRequest request) {
    started.add(request);
    final handle = _DyingHandle(_pid++, request);
    handles.add(handle);
    return handle;
  }
}

class _DyingHandle extends FakePtyHandle {
  _DyingHandle(super.pid, super.request);
  @override
  void kill([int signal = 15]) {
    super.kill(signal);
    finish(128 + signal);
  }
}

/// Slice 5b: the one launch path — every decision the app's launcher made,
/// made by the server, and the agent started as one of its terminals.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);
  final local = Platform.isWindows ? 'windowsNative' : 'localPosix';

  late AppDatabase database;
  late SessionRegistry registry;
  late _DyingLauncher pty;
  late ServerSessionLauncher launches;
  late Directory temp;
  var ids = 0;
  Map<String, ConversationPresence> presence = {};
  bool directoryThere = true;
  Map<String, String> hostEnvironment = const {};
  bool usableLogin = false;
  Set<String> vault = const {};
  AgentTerminalOpener? openAgent;

  ServerSessionLauncher build() {
    final rows = CheckoutRows(database);
    final launcher = HostedAgentLauncher(
      registry: registry,
      sessions: SessionDao(database),
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
      now: () => t0,
      newId: () => 'new-${++ids}',
      hostEnvironment: hostEnvironment,
      environmentOf: rows.environment,
      settings: () =>
          LaunchSettings.parse(database.readMetadata('settings.v1')),
      hasUsableLogin: (_) async => usableLogin,
      vaultNames: () => vault,
      handoffFiles: HandoffPacketFiles(
        Directory('${temp.path}${Platform.pathSeparator}handoff'),
      ),
      links: SessionRepositoryDao(database),
      openAgent: openAgent,
      // These cases read the prompt off argv; how a Windows-native launch
      // carries a long one is wsl_hosted_launch_test's.
      windows: false,
    );
    return ServerSessionLauncher(
      launcher: launcher,
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      settings: () =>
          LaunchSettings.parse(database.readMetadata('settings.v1')),
      presenceOf: (agent, conversation) async =>
          presence[conversation] ?? ConversationPresence.unknown,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => directoryThere,
    );
  }

  setUp(() {
    ids = 0;
    presence = {};
    directoryThere = true;
    hostEnvironment = const {};
    usableLogin = false;
    vault = const {};
    temp = Directory.systemTemp.createTempSync('launcher_test');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, ssh_host_id, '
      'created_at) VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?);',
      [
        'local', local, 'Here', null, '$t0', //
        'box', 'ssh', 'Box', 'h1', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), '
      '(?, ?, ?, ?, ?, ?);',
      [
        'r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0', //
        'r3', 'p3', 'other', 'local', '/src/other', '$t0', //
        'r9', 'p9', 'far', 'box', '/home/u/far', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1, //
        'c1', AgentIds.codex, 'local', '/bin/codex', '$t0', 1, //
        'a9', AgentIds.claudeCode, 'box', '/usr/bin/claude', '$t0', 1,
      ],
    );
    pty = _DyingLauncher();
    registry = SessionRegistry(launcher: pty);
    openAgent = null;
    launches = build();
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  Session insert(
    String id, {
    String repositoryId = 'r1',
    String installationId = 'a1',
    String? conversation,
    String? parent,
    EnvironmentPath? directory,
  }) {
    final row = Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: installationId,
      title: 'Row $id',
      useWorktree: false,
      status: SessionStatus.completed,
      createdAt: t0,
      externalSessionId: conversation,
      parentSessionId: parent,
      parentLink: parent == null ? null : SessionLink.spawn,
      workingDirectory: directory,
    );
    SessionDao(database).insert(row);
    return row;
  }

  String argv() => pty.started.last.argv.join(' ');
  Session row(String id) => SessionDao(database).getById(id)!;

  test('a new session writes its row and opens karmashala_<id>', () async {
    final started = await launches.start(
      const SessionStartSpec(
        repositoryId: 'r1',
        installationId: 'a1',
        title: 'Fix the cart',
        prompt: 'go',
      ),
    );
    expect(started.sessionId, 'new-1');
    expect(started.adopted, isFalse);
    expect(started.launch?.sessionId, 'new-1');
    expect(row('new-1').status, SessionStatus.running);
    expect(row('new-1').externalSessionId, 'new-1');
    expect(registry.find('karmashala_new-1'), isNotNull);
    expect(argv(), contains('--session-id new-1'));
    expect(pty.started.last.argv.last, 'go');
  });

  test('Settings decide the mode and model nobody chose', () async {
    database.writeMetadata(
      'settings.v1',
      jsonEncode({
        'permissions': {
          AgentIds.claudeCode: {'newSessions': 'mode=acceptEdits'},
        },
        'defaultModels': {AgentIds.claudeCode: 'opus'},
      }),
    );
    await launches.start(
      const SessionStartSpec(
        repositoryId: 'r1',
        installationId: 'a1',
        title: 't',
      ),
    );
    expect(argv(), contains('--permission-mode acceptEdits'));
    expect(argv(), contains('opus'));
    // Only what was chosen is recorded: the row still follows Settings.
    expect(row('new-1').permissionMode, isNull);
  });

  test('a chosen mode outranks Settings and is recorded', () async {
    database.writeMetadata(
      'settings.v1',
      jsonEncode({
        'permissions': {
          AgentIds.claudeCode: {'newSessions': 'mode=acceptEdits'},
        },
      }),
    );
    await launches.start(
      const SessionStartSpec(
        repositoryId: 'r1',
        installationId: 'a1',
        title: 't',
        permissionMode: 'mode=plan',
      ),
    );
    expect(argv(), contains('--permission-mode plan'));
    expect(row('new-1').permissionMode, 'mode=plan');
  });

  test(
    'resume continues the row\'s own conversation, in the same row',
    () async {
      insert('s1', conversation: 'conv-1');
      final started = await launches.resume('s1');
      expect(started.sessionId, 's1');
      expect(argv(), contains('--resume conv-1'));
      expect(argv(), isNot(contains('--session-id')));
      expect(registry.find('karmashala_s1'), isNotNull);
      expect(row('s1').status, SessionStatus.running);
    },
  );

  test(
    'a session already running is answered adopted, nothing started',
    () async {
      insert('s1', conversation: 'conv-1');
      await launches.resume('s1');
      final before = pty.started.length;
      final again = await launches.resume('s1');
      expect(again.adopted, isTrue);
      expect(again.launch?.sessionId, 's1');
      expect(pty.started.length, before);
    },
  );

  test('two resumes of one row at once start one process; the second is '
      'answered adopted', () async {
    insert('s1', conversation: 'conv-1');
    final first = launches.resume('s1', prompt: 'carry on');
    final second = launches.resume('s1');
    final answers = await Future.wait([first, second]);
    expect(pty.started, hasLength(1));
    expect(answers.first.adopted, isFalse);
    expect(answers.last.adopted, isTrue);
  });

  test('a row with no conversation gets a fresh one in the same row, '
      'under its own id', () async {
    insert('s1');
    final started = await launches.resume('s1');
    expect(started.sessionId, 's1');
    expect(argv(), contains('--session-id s1'));
    expect(argv(), isNot(contains('--resume')));
    expect(row('s1').externalSessionId, 's1');
    expect(SessionDao(database).getAll(), hasLength(1));
  });

  test('restart ends the running agent, then resumes it', () async {
    insert('s1', conversation: 'conv-1');
    await launches.resume('s1');
    final first = pty.handles.last;
    await launches.resume('s1', restart: true);
    expect(first.signals, isNotEmpty);
    expect(pty.started, hasLength(2));
    expect(argv(), contains('--resume conv-1'));
    expect(registry.find('karmashala_s1'), isNotNull);
  });

  test(
    'restart without a conversation is refused before anything ends',
    () async {
      insert('s1');
      await expectLater(
        launches.resume('s1', restart: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('has not named a conversation'),
          ),
        ),
      );
      expect(pty.started, isEmpty);
    },
  );

  test(
    'a child\'s prompt is prefixed with the line naming its parent',
    () async {
      insert('boss');
      final started = await launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'a1',
          title: 't',
          prompt: 'write tests',
          parentSessionId: 'boss',
        ),
      );
      expect(started.depth, 1);
      expect(pty.started.last.argv.last, startsWith('[message from'));
      expect(pty.started.last.argv.last, contains('Row boss'));
      expect(pty.started.last.argv.last, endsWith('write tests'));
      expect(row('new-1').parentLink, SessionLink.spawn);
    },
  );

  test('past the spawn depth is refused, nothing started', () async {
    insert('a');
    insert('b', parent: 'a');
    insert('c', parent: 'b');
    await expectLater(
      launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'a1',
          title: 't',
          parentSessionId: 'c',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(pty.started, isEmpty);
  });

  test(
    'a directory that has gone falls back to the checkout, in words',
    () async {
      directoryThere = false;
      final started = await launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'a1',
          title: 't',
          workingDirectory: EnvironmentPath(
            environmentId: 'local',
            path: '/src/shop/api/gone',
          ),
        ),
      );
      expect(started.workingDirectoryNotice, contains('no longer exists'));
      expect(pty.started.last.workingDirectory, '/src/shop/api');
      // The record is kept: a missing folder is often temporary.
      expect(row('new-1').workingDirectory, isNull);
    },
  );

  test('a second process on a held conversation is refused for an agent '
      'that will not share one', () async {
    insert('held', repositoryId: 'r3', installationId: 'c1', conversation: 'x');
    await launches.resume('held');
    await expectLater(
      launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'c1',
          title: 't',
          newSession: false,
          resumeConversationId: 'x',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('is already running in Karmashala'),
        ),
      ),
    );
    expect(pty.started, hasLength(1));
  });

  test('a conversation the agent never wrote is refused in words', () async {
    insert('s1', conversation: 's1');
    presence = {'s1': ConversationPresence.absent};
    await expectLater(
      launches.resume('s1'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cannot be resumed'),
        ),
      ),
    );
    expect(pty.started, isEmpty);
  });

  test(
    'a row pointed elsewhere goes back to its own conversation, repaired',
    () async {
      insert('s1', conversation: 'elsewhere');
      presence = {
        'elsewhere': ConversationPresence.absent,
        's1': ConversationPresence.present,
      };
      await launches.resume('s1');
      expect(argv(), contains('--resume s1'));
      expect(row('s1').externalSessionId, 's1');
    },
  );

  test('the external surface answers the command and spawns nothing', () async {
    final started = await launches.start(
      const SessionStartSpec(
        repositoryId: 'r1',
        installationId: 'a1',
        title: 't',
        surface: SessionSurface.external,
      ),
    );
    expect(started.external?.executable, '/bin/claude');
    expect(started.external?.workingDirectory, '/src/shop/api');
    expect(started.session.status, SessionStatus.unknown);
    expect(row('new-1').status, SessionStatus.unknown);
    expect(pty.started, isEmpty);
  });

  test('an SSH checkout starts on its box, through the server\'s own '
      'terminals (slice 5d): nothing is handed to a client', () async {
    final onBox = <AgentPaneLaunch>[];
    openAgent = (launch, columns, rows) async => onBox.add(launch);
    launches = build();
    final started = await launches.start(
      const SessionStartSpec(repositoryId: 'r9', installationId: 'a9', title: 't'),
    );
    expect(started.launch?.sshHostId, 'h1');
    expect(started.launch?.sessionId, 'new-1');
    expect(started.hostSessionId, 'karmashala_new-1');
    expect(onBox.single.sshHostId, 'h1');
    expect(onBox.single.sessionId, 'new-1');
    expect(pty.started, isEmpty);
  });

  test('with no terminals to open it through, an SSH checkout is refused '
      'in words and its row does not claim to run', () async {
    await expectLater(
      launches.start(
        const SessionStartSpec(repositoryId: 'r9', installationId: 'a9', title: 't'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(row('new-1').status, isNot(SessionStatus.running));
    expect(pty.started, isEmpty);
  });

  test('a packet travels as a file to an agent that takes one', () async {
    await launches.start(
      const SessionStartSpec(
        repositoryId: 'r1',
        installationId: 'a1',
        title: 't',
        prompt: 'do it',
        systemPrompt: 'THE PACKET',
      ),
    );
    final file = File(
      '${temp.path}${Platform.pathSeparator}handoff'
      '${Platform.pathSeparator}handoff-new-1.md',
    );
    expect(file.readAsStringSync(), 'THE PACKET');
    expect(argv(), contains('--append-system-prompt-file ${file.path}'));
    expect(pty.started.last.argv.last, 'do it');
  });

  test(
    'a packet is the opening prompt for an agent with no such file',
    () async {
      await launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'c1',
          title: 't',
          prompt: 'do it',
          systemPrompt: 'THE PACKET',
        ),
      );
      expect(pty.started.last.argv.last, 'THE PACKET');
    },
  );

  group('inherited Anthropic credentials', () {
    setUp(() {
      hostEnvironment = const {'ANTHROPIC_API_KEY': 'sk-secret'};
    });

    test('withheld when a login exists, and said so', () async {
      usableLogin = true;
      launches = build();
      final started = await launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'a1',
          title: 't',
        ),
      );
      expect(
        pty.started.last.removedEnvironment,
        contains('ANTHROPIC_API_KEY'),
      );
      expect(started.credentialNotice, isNotNull);
      expect(started.credentialNotice, isNot(contains('sk-secret')));
    });

    test('kept with no login to fall back on', () async {
      usableLogin = false;
      launches = build();
      await launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'a1',
          title: 't',
        ),
      );
      expect(
        pty.started.last.removedEnvironment,
        isNot(contains('ANTHROPIC_API_KEY')),
      );
    });

    test('kept when the vault sets that name', () async {
      usableLogin = true;
      vault = {'ANTHROPIC_API_KEY'};
      launches = build();
      await launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'a1',
          title: 't',
        ),
      );
      expect(
        pty.started.last.removedEnvironment,
        isNot(contains('ANTHROPIC_API_KEY')),
      );
    });
  });
}
