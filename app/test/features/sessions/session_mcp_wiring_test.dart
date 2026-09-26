import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/session_mcp.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// A launched session actually being told the tools exist — the gap this whole
/// mechanism closes.
///
/// `LauncherMcp.ensureConfig` had no caller in the app and `AgentLaunchSpec` had
/// no field to carry one, so 63 tools were served and no session was ever told.
/// The cases here are the two surfaces carrying it, the fail-soft rules, and —
/// at the bottom — a real HTTP tool call made against the URL taken out of the
/// file a real launch wrote, which is the only proof that matters.
void main() {
  const terminal = SystemTerminal(
    kind: SystemTerminalKind.windowsTerminal,
    label: 'Windows Terminal',
    executable: 'wt.exe',
  );

  AppDatabase seededDatabase() {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db)
      ..insert(agentInstallation(agentId: AgentIds.claudeCode))
      ..insert(agentInstallation(id: 'a2', agentId: AgentIds.codex));
    return db;
  }

  /// A container over [db]. The id prefix is a parameter because a second
  /// container over one database is what a restart *is*, and two generators
  /// counting from zero would hand out ids the first run already used.
  ProviderContainer containerOver(
    AppDatabase db, {
    SessionMcp? mcp,
    String idPrefix = 's-',
    FakeCommandRunner? runner,
  }) => ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator(idPrefix)),
      agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
      hostCommandRunnerProvider.overrideWithValue(
        runner ?? FakeCommandRunner(),
      ),
      if (mcp != null)
        sessionMcpProvider.overrideWith(() => _StaticSessionMcp(mcp)),
    ],
  );

  ({ProviderContainer container, AppDatabase db, FakeCommandRunner runner})
  harness({SessionMcp? mcp}) {
    final db = seededDatabase();
    final runner = FakeCommandRunner();
    return (
      container: containerOver(db, mcp: mcp, runner: runner),
      db: db,
      runner: runner,
    );
  }

  Future<SessionLaunchResult> launchIn(
    ProviderContainer container, {
    String agentId = AgentIds.claudeCode,
    String installationId = 'a1',
  }) => container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(id: installationId, agentId: agentId),
          title: 'Work',
          purpose: SessionPurpose.newSession,
        ),
      );

  /// What the pane would actually run, which is the two halves put together.
  List<String> paneCommand(ProviderContainer container, String paneId) =>
      container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId)!
          .agentLaunch!
          .commandArguments;

  Future<List<String>> paneArguments(
    ProviderContainer container, {
    String agentId = AgentIds.claudeCode,
    String installationId = 'a1',
  }) async {
    final launched = await container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(
              id: installationId,
              agentId: agentId,
            ),
            title: 'Work',
            purpose: SessionPurpose.newSession,
          ),
        );
    return paneCommand(container, launched.paneId!);
  }

  group('a pane launch carries it', () {
    test('Claude Code is handed the config file it can open', () async {
      final h = harness(mcp: _FixedMcp(configPath: '/mnt/c/x/session.json'));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(
        await paneArguments(h.container),
        contains('--mcp-config=/mnt/c/x/session.json'),
      );
    });

    test('Codex is handed the URL, and no file is asked for', () async {
      final mcp = _FixedMcp(configPath: '/mnt/c/x/session.json');
      final h = harness(mcp: mcp);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final args = await paneArguments(
        h.container,
        agentId: AgentIds.codex,
        installationId: 'a2',
      );

      expect(
        args,
        containsAllInOrder(['-c', 'mcp_servers.karmashala.url=$_url']),
      );
      expect(mcp.askedForAFile, isFalse);
    });

    test(
      'the session named in the URL is the session that was launched',
      () async {
        final mcp = _FixedMcp(configPath: '/mnt/c/x/session.json');
        final h = harness(mcp: mcp);
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await h.container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: agentInstallation(agentId: AgentIds.claudeCode),
                title: 'Work',
                purpose: SessionPurpose.newSession,
              ),
            );

        expect(mcp.sessionIds, [launched.session.id]);
      },
    );
  });

  group('an external terminal carries the same thing', () {
    test('because both surfaces share one argument builder', () async {
      // "Open this in Windows Terminal instead" must produce the same agent, on
      // the same endpoint, speaking as the same session.
      final h = harness(mcp: _FixedMcp(configPath: r'C:\x\session.json'));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: AgentIds.claudeCode),
              title: 'Work',
              purpose: SessionPurpose.newSession,
              surface: SessionSurface.external,
            ),
            externalTerminal: terminal,
          );

      expect(
        h.runner.startRequests.single.arguments.join(' '),
        contains(r'--mcp-config=C:\x\session.json'),
      );
    });
  });

  /// The bug this group exists for. The owner restarted the app, started a
  /// restored pane, and the agent refused:
  ///
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: `…/karmashala/mcp/session-<uuid>.json`
  ///
  /// `SessionMcpConfigs.prepare` empties that directory on every start, the
  /// control server binds a new port and mints a new credential — so all three
  /// values in a stored MCP flag are dead by the time the pane is restarted.
  group('a restarted pane is re-armed, not replayed', () {
    test('it is given the endpoint that exists now', () async {
      final db = seededDatabase();
      addTearDown(db.close);

      final first = containerOver(
        db,
        mcp: _FixedMcp(
          url: 'http://127.0.0.1:1111/mcp/yesterday',
          configPath: '/gone/session-abc.json',
        ),
      );
      final paneId = (await launchIn(first)).paneId!;
      expect(
        paneCommand(first, paneId),
        contains('--mcp-config=/gone/session-abc.json'),
      );
      first.read(terminalSessionsControllerProvider.notifier).persistLayout();
      first.dispose();

      // The restart: a different port, a different credential, a config
      // directory that was emptied on the way in.
      final next = containerOver(
        db,
        idPrefix: 't-',
        mcp: _FixedMcp(
          url: 'http://127.0.0.1:2222/mcp/today',
          configPath: '/live/session-abc.json',
        ),
      );
      addTearDown(next.dispose);
      next.read(terminalSessionsControllerProvider.notifier).startPane(paneId);

      final args = paneCommand(next, paneId);
      expect(args, contains('--mcp-config=/live/session-abc.json'));
      expect(args, isNot(contains('--mcp-config=/gone/session-abc.json')));
      // The durable half is untouched: the pane still runs under the mode and
      // the id it was launched with.
      expect(
        args,
        containsAllInOrder([
          '--permission-mode',
          'manual',
          '--session-id',
          's-0',
        ]),
      );
    });

    test('Codex is given the port and credential of now', () async {
      // Codex carries the URL itself, so both halves of the staleness — the
      // port and the token — are visible in one argument.
      final db = seededDatabase();
      addTearDown(db.close);

      final first = containerOver(
        db,
        mcp: _FixedMcp(url: 'http://127.0.0.1:1111/mcp/yesterday'),
      );
      final paneId = (await launchIn(
        first,
        agentId: AgentIds.codex,
        installationId: 'a2',
      )).paneId!;
      first.read(terminalSessionsControllerProvider.notifier).persistLayout();
      first.dispose();

      final next = containerOver(
        db,
        idPrefix: 't-',
        mcp: _FixedMcp(url: 'http://127.0.0.1:2222/mcp/today'),
      );
      addTearDown(next.dispose);
      next.read(terminalSessionsControllerProvider.notifier).startPane(paneId);

      expect(
        paneCommand(next, paneId),
        containsAllInOrder([
          '-c',
          'mcp_servers.karmashala.url=http://127.0.0.1:2222/mcp/today',
        ]),
      );
      expect(paneCommand(next, paneId).join(' '), isNot(contains('yesterday')));
    });

    test(
      'with the control server down it starts with no MCP flags at all',
      () async {
        // The ordinary case, and the one the whole mechanism fails soft into: a
        // pane without its tools is a smaller loss than a pane that will not
        // open. Never a stale flag instead.
        final db = seededDatabase();
        addTearDown(db.close);

        final first = containerOver(
          db,
          mcp: _FixedMcp(configPath: '/gone/session-abc.json'),
        );
        final paneId = (await launchIn(first)).paneId!;
        first.read(terminalSessionsControllerProvider.notifier).persistLayout();
        first.dispose();

        final next = containerOver(db, idPrefix: 't-');
        addTearDown(next.dispose);
        next
            .read(terminalSessionsControllerProvider.notifier)
            .startPane(paneId);

        expect(paneCommand(next, paneId), [
          '--permission-mode',
          'manual',
          '--session-id',
          's-0',
        ]);
      },
    );

    test('a layout saved before the fix loses the flag it baked in', () async {
      // The owner will restore an existing layout, whose rows still carry
      // the MCP flag inside `arguments`. Installing the fix has to repair
      // those, not merely stop writing new ones.
      final db = seededDatabase();
      addTearDown(db.close);

      final first = containerOver(db);
      final paneId = (await launchIn(first)).paneId!;
      first.read(terminalSessionsControllerProvider.notifier).persistLayout();
      first.dispose();

      db.execute('UPDATE terminal_panes SET launch_command = ? WHERE id = ?;', [
        jsonEncode({
          'agentId': AgentIds.claudeCode,
          'executable': 'claude',
          'arguments': [
            r'--mcp-config=C:\Users\d\AppData\Roaming\com.popupbits'
                r'\karmashala\mcp\session-95659659.json',
            '--permission-mode',
            'manual',
            '--session-id',
            's-0',
          ],
          'sessionId': 's-0',
        }),
        paneId,
      ]);

      final next = containerOver(db, idPrefix: 't-');
      addTearDown(next.dispose);
      next.read(terminalSessionsControllerProvider.notifier).startPane(paneId);

      expect(paneCommand(next, paneId), [
        '--permission-mode',
        'manual',
        '--session-id',
        's-0',
      ]);
    });
  });

  group('nothing changes when there is nothing to say', () {
    test('no control server means the launch of yesterday', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(await paneArguments(h.container), [
        '--permission-mode',
        'manual',
        '--session-id',
        's-0',
      ]);
    });

    test(
      'an endpoint that cannot be reached from here changes nothing',
      () async {
        // What a session over SSH gets, and a WSL session on a host with no
        // switch: the provisioner answers null and the command line is untouched.
        final h = harness(mcp: _FixedMcp(access: null));
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        expect(await paneArguments(h.container), [
          '--permission-mode',
          'manual',
          '--session-id',
          's-0',
        ]);
      },
    );

    test('a provisioner that throws never fails a launch', () async {
      // The one rule that outranks everything else here: a session that opens
      // without its tools is a smaller loss than a session that does not open.
      final h = harness(mcp: _ThrowingMcp());
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(await paneArguments(h.container), [
        '--permission-mode',
        'manual',
        '--session-id',
        's-0',
      ]);
    });
  });

  test(
    'end to end: the launched session calls a tool through its own config',
    () async {
      // The whole path, with nothing faked between the launch and the tool: a
      // real control server, a real config file written to disk by a real
      // launch, the URL read back out of that file, a real HTTP request to it,
      // and a tool that answers about the caller without being told who it is.
      final tmp = Directory.systemTemp.createTempSync('karmashala_mcp_e2e_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final server = LauncherControlServer(h.container);
      await server.start(
        bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
        socketDirectory: p.join(tmp.path, 'ipc'),
        sessionConfigDirectory: p.join(tmp.path, 'mcp'),
        wslHostAddress: () async => null,
      );
      addTearDown(server.stop);

      final launched = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: AgentIds.claudeCode),
              title: 'Driven from inside',
              purpose: SessionPurpose.newSession,
            ),
          );

      // 1. The launch put a config flag on the agent's command line.
      final args = paneCommand(h.container, launched.paneId!);
      final flag = args.firstWhere((a) => a.startsWith('--mcp-config='));

      // 2. The file it names is really there, and names one URL.
      final config =
          jsonDecode(File(flag.split('=').last).readAsStringSync())
              as Map<String, Object?>;
      final url =
          ((config['mcpServers']! as Map<String, Object?>)['karmashala']!
                  as Map<String, Object?>)['url']!
              as String;

      // 3. That URL answers a real MCP tool call…
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/event-stream',
      );
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          // No sessionId argument at all — the point of the next assertion.
          'params': <String, Object?>{
            'name': 'session_transcript',
            'arguments': <String, Object?>{},
          },
          '_meta': <String, Object?>{
            'io.modelcontextprotocol/protocolVersion': '2026-07-28',
          },
        }),
      );
      final response = await request.close();
      final body =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;

      expect(response.statusCode, 200);
      final result = body['result']! as Map<String, Object?>;
      expect(result['isError'], isNot(true), reason: '$body');

      // 4. …and the tool acted on the session that was launched, without the
      // agent naming it. That is the identity property: the app stamped it into
      // the URL, and the model could not have said it.
      final structured = result['structuredContent'] as Map<String, Object?>?;
      final reported =
          structured ??
          jsonDecode(
                ((result['content']! as List<Object?>).first
                        as Map<String, Object?>)['text']!
                    as String,
              )
              as Map<String, Object?>;
      expect(reported['sessionId'], launched.session.id);
      expect(reported['title'], 'Driven from inside');
    },
  );
}

const _url = 'http://127.0.0.1:51234/mcp/session-token';

/// A [SessionMcp] that answers the same thing every time and records what it
/// was asked.
class _FixedMcp implements SessionMcp {
  _FixedMcp({this.configPath, this.access = _unset, this.url = _url});

  static const Object _unset = Object();

  /// What a file-taking agent is told to open, when one is asked for.
  final String? configPath;

  /// The endpoint. A parameter because a restart mints a new one — a new port
  /// and a new credential — and a restored pane has to be given *that*.
  final String url;

  /// Pass `null` explicitly for a provisioner that has nothing to offer.
  final Object? access;

  final List<String> sessionIds = [];
  bool askedForAFile = false;

  @override
  SessionMcpAccess? accessFor({
    required String sessionId,
    required ExecutionEnvironment environment,
    required bool withConfigFile,
  }) {
    sessionIds.add(sessionId);
    askedForAFile |= withConfigFile;
    if (!identical(access, _unset)) return null;
    return SessionMcpAccess(
      url: url,
      configPath: withConfigFile ? configPath : null,
    );
  }
}

/// The pathological provisioner: whatever goes wrong in there, a launch must
/// still happen.
class _ThrowingMcp implements SessionMcp {
  @override
  SessionMcpAccess? accessFor({
    required String sessionId,
    required ExecutionEnvironment environment,
    required bool withConfigFile,
  }) => throw StateError('the endpoint fell over');
}

class _StaticSessionMcp extends SessionMcpController {
  _StaticSessionMcp(this._mcp);
  final SessionMcp _mcp;

  @override
  SessionMcp? build() => _mcp;
}
