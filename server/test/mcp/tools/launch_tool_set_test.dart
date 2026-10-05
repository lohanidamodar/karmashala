import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/mcp/tools/launch_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/sessions/launch/launch_settings.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Every executable path answers present: the launch's own stat is not what
/// these tests are about.
final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// `open_new_session` (slice 5b): always the server's, through the one launch
/// path — recorded as the caller's child, under the caps the app applied —
/// and shown in the window a person last used, or said plainly that none is.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late ServerToolContext context;
  late LaunchToolSet tools;
  var ids = 0;
  late List<(String, EnvironmentPath)> trusted;
  late ServerSessionLauncher launches;
  var settings = LaunchSettings.none;

  setUp(() {
    ids = 0;
    trusted = [];
    settings = LaunchSettings.none;
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?), (?, ?, ?, ?);',
      [
        'local', Platform.isWindows ? 'windowsNative' : 'localPosix', 'Here',
        t0.toIso8601String(), //
        'wsl1', 'wsl', 'Ubuntu', t0.toIso8601String(),
      ],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0', //
        'r2', 'p2', 'far', 'wsl1', '/home/u/far', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1, //
        'a2', AgentIds.claudeCode, 'wsl1', '/usr/bin/claude', '$t0', 1,
      ],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    context = ServerToolContext(
      database: database,
      data: DataService(database, clock: () => t0),
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    final rows = CheckoutRows(database);
    final launcher = HostedAgentLauncher(
      registry: registry,
      sessions: SessionDao(database),
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
      now: () => t0,
      newId: () => 'new-${++ids}',
      hostEnvironment: const {},
      environmentOf: rows.environment,
    );
    launches = ServerSessionLauncher(
      launcher: launcher,
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: context.data.installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
      trustScratchFolder: (installation, folder) async =>
          trusted.add((installation.id, folder)),
      settings: () => settings,
    );
    tools = LaunchToolSet(context, launches: launches);
  });

  tearDown(() async {
    context.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  Session insertCaller(String id, {String? parent, String? mode}) {
    final row = Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Orchestrator $id',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: t0,
      parentSessionId: parent,
      parentLink: parent == null ? null : SessionLink.spawn,
      permissionMode: mode,
    );
    SessionDao(database).insert(row);
    return row;
  }

  test('with no window open, the session still starts and the answer says '
      'nothing was shown — at once, no waiting for a window', () async {
    final answer =
        (await tools
                .call('open_new_session', {'projectId': 'p1'}, null)!
                .timeout(const Duration(seconds: 5)))
            as Map<String, Object?>;
    expect(registry.find('karmashala_new-1'), isNotNull);
    expect(answer['where'], contains('no Karmashala window is open'));
  });

  test('a window a person last used is asked to open a tab on it', () async {
    final told = <DataChange>[];
    final window = context.data.open((batch) => told.addAll(batch.changes));
    window.handle(const DataSubscribe());
    final answer =
        (await tools.call('open_new_session', {'projectId': 'p1'}, null)!)
            as Map<String, Object?>;
    expect(answer['where'], contains('shown in a tab'));
    final intent = told.whereType<OpenSessionTab>().single;
    expect(intent.sessionId, 'new-1');
    expect(intent.launch?.sessionId, 'new-1');
    window.close();
  });

  test('starts the agent here as the caller\'s child, the prompt under the '
      'caller\'s name', () async {
    insertCaller('caller');
    final answer =
        (await tools.call('open_new_session', {
              'projectId': 'p1',
              'title': 'Write the tests',
              'prompt': 'add a test for the cart',
            }, 'caller')!)
            as Map<String, Object?>;

    expect(answer['sessionId'], 'new-1');
    expect(answer['depth'], 1);
    final row = SessionDao(database).getById('new-1')!;
    expect(row.parentSessionId, 'caller');
    expect(row.parentLink, SessionLink.spawn);
    expect(row.title, 'Write the tests');
    expect(registry.find('karmashala_new-1'), isNotNull);
    final argv = pty.started.last.argv.join(' ');
    expect(
      argv,
      contains(
        '[message from the Karmashala session "Orchestrator caller" (caller)]',
      ),
    );
  });

  test('an agent starting in a scratch folder has it marked trusted first; '
      'one in an ordinary project does not', () async {
    insertCaller('caller');
    await tools.call('open_new_session', {
      'projectId': 'p1',
      'title': 'Ordinary',
    }, 'caller');
    expect(trusted, isEmpty);

    database.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      'created_at, kind) VALUES (?, ?, ?, ?, ?, ?);',
      ['p1', 'Scratch', 'local', '/src/shop', '$t0', 'scratch'],
    );
    await tools.call('open_new_session', {
      'projectId': 'p1',
      'title': 'In scratch',
    }, 'caller');
    expect(trusted, [
      (
        'a1',
        const EnvironmentPath(environmentId: 'local', path: '/src/shop/api'),
      ),
    ]);
  });

  test('a title the caller names is kept as chosen, so the agent\'s own '
      'name never replaces it; none leaves the naming to the agent', () async {
    insertCaller('caller');
    await tools.call('open_new_session', {
      'projectId': 'p1',
      'title': 'Chat: inline diffs',
    }, 'caller');
    final named = SessionDao(database).getById('new-1')!;
    expect(named.title, 'Chat: inline diffs');
    expect(named.titleByUser, isTrue);

    await tools.call('open_new_session', {'projectId': 'p1'}, 'caller');
    final unnamed = SessionDao(database).getById('new-2')!;
    expect(unnamed.titleByUser, isFalse);
    expect(isPlaceholderSessionTitle(unnamed.title), isTrue);
  });

  test('an untitled spawn is named from its prompt, not from the line '
      'naming its caller', () async {
    insertCaller('caller');
    final answer =
        (await tools.call('open_new_session', {
              'projectId': 'p1',
              'prompt': 'Fix the cart totals\n\nThey round wrong.',
            }, 'caller')!)
            as Map<String, Object?>;
    expect(answer['title'], 'Fix the cart totals');
    final row = SessionDao(database).getById('new-1')!;
    expect(row.title, 'Fix the cart totals');
    expect(row.titleByUser, isFalse);
  });

  test('refuses past the spawn depth, nothing started', () async {
    insertCaller('root');
    insertCaller('child', parent: 'root');
    insertCaller('grandchild', parent: 'child');
    await expectLater(
      tools.call('open_new_session', {'projectId': 'p1'}, 'grandchild'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('levels deep'),
        ),
      ),
    );
    expect(pty.started, isEmpty);
  });

  test('refuses a named mode above the spawn ceiling', () async {
    insertCaller('caller');
    await expectLater(
      tools.call('open_new_session', {
        'projectId': 'p1',
        'permissionMode': 'bypass',
      }, 'caller'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a WSL checkout off Windows is refused in words', () async {
    if (Platform.isWindows) return;
    await expectLater(
      tools.call('open_new_session', {'projectId': 'p2'}, null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('this server is not on Windows'),
        ),
      ),
    );
    expect(pty.started, isEmpty);
  });

  group('how the session runs', () {
    /// Claude Code's chat form beside its terminal form here.
    void installChat() => database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['c1', AgentIds.claudeAcp, 'local', '/bin/claude', '$t0', 0],
    );

    LaunchSettings chosen(String form) => LaunchSettings.parse(
      '{"agentRunForms": {"${AgentIds.claudeCode}": "$form"}}',
    );

    test('Settings are read for each agent\'s chosen form', () {
      expect(
        chosen('chat').chosenRunFormOf(AgentIds.claudeCode),
        AgentRunForm.chat,
      );
      expect(LaunchSettings.none.chosenRunFormOf(AgentIds.claudeCode), isNull);
    });

    test('with nothing named, the default agent runs in the form a person '
        'chose for it', () {
      installChat();
      expect(launches.defaultInstallationIn('local')!.id, 'a1');
      settings = chosen('chat');
      expect(launches.defaultInstallationIn('local')!.id, 'c1');
    });

    test('a named form wins over the chosen one, for the default and for a '
        'named cli', () async {
      installChat();
      settings = chosen('chat');
      await tools.call('open_new_session', {
        'projectId': 'p1',
        'form': 'terminal',
      }, null);
      expect(SessionDao(database).getById('new-1')!.agentInstallationId, 'a1');
      await tools.call('open_new_session', {
        'projectId': 'p1',
        'cli': 'claude',
        'form': 'terminal',
      }, null);
      expect(SessionDao(database).getById('new-2')!.agentInstallationId, 'a1');
    });

    test('a named cli runs in the chosen form, as the default does', () {
      installChat();
      settings = chosen('chat');
      final terminal = launches
          .installationsIn('local')
          .singleWhere((i) => i.id == 'a1');
      expect(launches.installationFor(terminal).id, 'c1');
      // Chosen but not installed here: the agent runs as it can.
      expect(
        launches
            .installationFor(
              launches.installationsIn('wsl1').single,
            )
            .id,
        'a2',
      );
    });

    test('a form that is not installed there is refused, nothing started', () async {
      await expectLater(
        tools.call('open_new_session', {'projectId': 'p1', 'form': 'chat'}, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('chat'),
          ),
        ),
      );
      expect(pty.started, isEmpty);
    });

    test('a form named wrong is refused', () async {
      await expectLater(
        tools.call('open_new_session', {'projectId': 'p1', 'form': 'tui'}, null),
        throwsA(isA<ArgumentError>()),
      );
      expect(pty.started, isEmpty);
    });

    test('an installation named in the other form than the one asked for is '
        'refused', () async {
      await expectLater(
        tools.call('open_new_session', {
          'projectId': 'p1',
          'agentInstallationId': 'a1',
          'form': 'chat',
        }, null),
        throwsA(isA<StateError>()),
      );
    });

    test('both tools offer the form', () {
      for (final name in ['open_new_session', 'subagent_run']) {
        final schema = tools.schemas.singleWhere((s) => s['name'] == name);
        final properties =
            (schema['inputSchema']! as Map)['properties']! as Map;
        expect(properties, contains('form'), reason: name);
      }
    });
  });

  test('a cli nobody installed here is refused', () async {
    await expectLater(
      tools.call('open_new_session', {'projectId': 'p1', 'cli': 'codex'}, null),
      throwsA(isA<StateError>()),
    );
  });
}
