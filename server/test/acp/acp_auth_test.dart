import 'dart:async';
import 'dart:io' show ProcessException;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart'
    show AuthMethod, InitializeResult;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/src/acp/acp_auth.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';
import 'fake_codex_app_server.dart';

/// Logging in to an ACP agent at the server: its methods read over a
/// short-lived connection, `authenticate` asked and remembered only once it
/// succeeded, a terminal login opened as a terminal, a choice forgotten (with
/// `logout` where the agent offers it), and the remembered method handed to
/// the next start. Every agent is the fake; no process runs.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);
  final wsl = ExecutionEnvironment(
    id: 'wsl:Ubuntu',
    kind: EnvironmentKind.wsl,
    name: 'Ubuntu',
    wslDistribution: 'Ubuntu',
    createdAt: t0,
  );
  final antigravity = AgentInstallation(
    id: 'ag1',
    agentId: 'antigravity-acp',
    executable: const EnvironmentPath(
      environmentId: 'wsl:Ubuntu',
      path: '/home/me/agy_acp_server.par',
    ),
    createdAt: t0,
  );
  final windows = ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: t0,
  );
  final antigravityOnWindows = AgentInstallation(
    id: 'ag-win',
    agentId: 'antigravity-acp',
    executable: const EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\agy\agy_acp_server.exe',
    ),
    createdAt: t0,
  );
  final terminalAgent = AgentInstallation(
    id: 'cc1',
    agentId: AgentIds.claudeCode,
    executable: const EnvironmentPath(
      environmentId: 'wsl:Ubuntu',
      path: '/usr/bin/claude',
    ),
    createdAt: t0,
  );
  const methods = [
    AuthMethod(id: 'oauth-personal', name: 'Log in with Google'),
    AuthMethod(id: 'gemini-api-key', name: 'Use Gemini API key'),
    AuthMethod(id: 'login', name: 'Log in', type: 'terminal', args: ['login']),
    AuthMethod(
      id: 'cli-login',
      name: 'Log in with the CLI',
      meta: {
        'terminal-auth': {
          'command': 'copilot',
          'args': ['login'],
        },
      },
    ),
  ];

  late AppDatabase database;
  late List<CommandRequest> spawned;
  late List<FakeAcpAgent> agents;
  late List<AcpLoginTerminal> terminals;
  late Map<String, String> vault;
  late FakeAcpAgent Function() nextAgent;
  late List<String> agentStderr;
  late List<Uri> openedLinks;
  late List<AcpLoginProgress> told;
  late Future<int?> Function() terminalEnds;

  ServerAcpAuth auth({List<AgentInstallation> more = const []}) =>
      ServerAcpAuth(
        installations: () => [
          antigravity,
          terminalAgent,
          antigravityOnWindows,
          ...more,
        ],
        environments: () => [wsl, windows],
        registry: () => AgentRegistry.builtIn,
        choices: AcpAuthChoiceDao(database),
        spawn: (environment, request) async {
          expect(environment.id, isIn([wsl.id, windows.id]));
          spawned.add(request);
          final agent = nextAgent();
          agents.add(agent);
          return FakeAcpProcess(
            agent,
            errorLines: Stream.fromIterable(agentStderr),
          ).spawn();
        },
        vault: () => vault,
        openTerminal: (login) {
          terminals.add(login);
          return terminalEnds();
        },
        openLink: openedLinks.add,
        tell: told.add,
        now: () => t0,
        readTimeout: const Duration(seconds: 5),
        authenticateTimeout: const Duration(seconds: 5),
      );

  setUp(() {
    database = AppDatabase.memory();
    ExecutionEnvironmentDao(database)
      ..upsert(wsl)
      ..upsert(windows);
    AgentInstallationDao(database)
      ..insert(antigravity)
      ..insert(terminalAgent)
      ..insert(antigravityOnWindows);
    spawned = [];
    agents = [];
    terminals = [];
    vault = {};
    agentStderr = [];
    openedLinks = [];
    told = [];
    terminalEnds = () async => 0;
    nextAgent = () => FakeAcpAgent(authMethods: methods, supportsLogout: true);
  });
  tearDown(() => database.close());

  test('methods are read over a connection started as a probe is, with the '
      'terminal ones and the key variable the descriptor names', () async {
    final read = await auth().methods('ag1');
    expect(read.installationId, 'ag1');
    expect(read.supportsLogout, isTrue);
    expect(read.methods.map((m) => (m.id, m.terminal, m.apiKeyVariable)), [
      ('oauth-personal', false, null),
      ('gemini-api-key', false, 'GEMINI_API_KEY'),
      ('login', true, null),
      ('cli-login', true, null),
    ]);
    final request = spawned.single;
    expect(request.executable, '/home/me/agy_acp_server.par');
    expect(request.arguments, ['--uid=']);
    expect(request.workingDirectory!.path, '/tmp');
    expect(agents.single.receivedMethods, ['initialize']);
    expect(
      agents.single.initializeParams!['clientCapabilities'],
      containsPair('auth', {'terminal': true}),
    );
  });

  test('an installation that is not there, or not spoken to over ACP, is '
      'refused without starting anything', () async {
    await expectLater(
      auth().methods('nope'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
    await expectLater(
      auth().methods('cc1'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.invalid,
        ),
      ),
    );
    expect(spawned, isEmpty);
  });

  test('authenticate is asked over its own connection and remembered as '
      'confirmed once it succeeded', () async {
    final server = auth();
    final state = await server.authenticate('ag1', 'oauth-personal');
    expect(agents.single.authenticatedWith, 'oauth-personal');
    expect(state.methodName, 'Log in with Google');
    expect(state.confirmed, isTrue);
    expect(server.state('ag1')!.methodId, 'oauth-personal');
    expect(server.state('ag1')!.authenticatedAt, t0);
  });

  test('a WSL agent\'s login link is opened once on this machine: its own '
      'opener reaches no desktop there, and its callback is local', () async {
    const link =
        'https://accounts.google.com/o/oauth2/v2/auth?response_type=code'
        '&redirect_uri=http%3A%2F%2F127.0.0.1%3A41597%2F&state=s1';
    agentStderr = [
      'Open the following link to authenticate the ACP server: $link',
      'gio: $link: Operation not supported',
    ];
    final state = await auth().authenticate('ag1', 'oauth-personal');
    expect(state.confirmed, isTrue);
    expect(openedLinks, [Uri.parse(link)]);
  });

  test(
    'only an https link is opened, and a Windows agent opens its own',
    () async {
      agentStderr = [
        'see file:///etc/passwd or http://127.0.0.1:9/ for details',
      ];
      await auth().authenticate('ag1', 'oauth-personal');
      expect(openedLinks, isEmpty);

      agentStderr = ['Open the following link: https://accounts.google.com/x'];
      await auth().authenticate('ag-win', 'oauth-personal');
      expect(openedLinks, isEmpty);
    },
  );

  test('a bridged agent\'s login link is opened here wherever it runs: the '
      'bridge runs in this process and opens no browser of its own', () async {
    final codexOnWindows = AgentInstallation(
      id: 'cx-win',
      agentId: AgentIds.codexAcp,
      executable: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\codex\codex.exe',
      ),
      createdAt: t0,
    );
    AgentInstallationDao(database).insert(codexOnWindows);
    final codex = FakeCodexAppServer(account: null);
    final server = ServerAcpAuth(
      installations: () => [codexOnWindows],
      environments: () => [windows],
      registry: () => AgentRegistry.builtIn,
      choices: AcpAuthChoiceDao(database),
      spawn: (environment, request) async {
        spawned.add(request);
        return codex.transport;
      },
      openLink: openedLinks.add,
      now: () => t0,
      readTimeout: const Duration(seconds: 5),
      authenticateTimeout: const Duration(seconds: 5),
    );
    final state = await server.authenticate('cx-win', 'chatgpt');
    expect(state.confirmed, isTrue);
    expect(spawned.single.arguments, ['app-server']);
    expect(openedLinks, [Uri.parse('https://auth.example.com/oauth?state=1')]);
  });

  test('a browser login gets ten minutes; one not finished by then is ended '
      'and told in words, remembering nothing', () async {
    final silent = StreamController<List<int>>();
    addTearDown(silent.close);
    final waiting = ServerAcpAuth(
      installations: () => [antigravity],
      environments: () => [wsl],
      registry: () => AgentRegistry.builtIn,
      choices: AcpAuthChoiceDao(database),
      spawn: (_, _) async => AcpTransport.streams(
        output: silent.stream,
        input: StreamController<List<int>>(),
        exitCode: Completer<int>().future,
      ),
      authenticateTimeout: const Duration(milliseconds: 50),
    );
    await expectLater(
      waiting.authenticate('ag1', 'oauth-personal'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          'Antigravity · Chat was not logged in within 50 milliseconds, so the '
              'login was ended. Log in again and finish signing in in the '
              'browser it opens.',
        ),
      ),
    );
    expect(waiting.state('ag1'), isNull);
    expect(
      auth().authenticateTimeout,
      const Duration(seconds: 5),
      reason: 'the fixture sets its own',
    );
    expect(
      ServerAcpAuth(
        installations: () => const [],
        environments: () => const [],
        registry: () => AgentRegistry.builtIn,
        choices: AcpAuthChoiceDao(database),
        spawn: (_, _) => throw StateError('unused'),
      ).authenticateTimeout,
      kAcpAgentLoginPatience,
    );
    expect(kAcpAgentLoginPatience, const Duration(minutes: 10));
  });

  test('a refused authenticate is told in the agent\'s words and changes '
      'nothing remembered', () async {
    final server = auth();
    await server.authenticate('ag1', 'oauth-personal');
    nextAgent = () => FakeAcpAgent(
      authMethods: methods,
      authenticateRefusal: 'your organisation does not allow this',
    );
    await expectLater(
      server.authenticate('ag1', 'oauth-personal'),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.failed)
            .having(
              (r) => r.message,
              'message',
              contains('your organisation does not allow this'),
            ),
      ),
    );
    expect(server.state('ag1')!.methodId, 'oauth-personal');
  });

  test('an API-key method needs its key in the vault, and the key reaches '
      'that connection alone', () async {
    final server = auth();
    await expectLater(
      server.authenticate('ag1', 'gemini-api-key'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          contains('GEMINI_API_KEY'),
        ),
      ),
    );
    expect(spawned, isEmpty);

    vault = {'GEMINI_API_KEY': 'k-123', 'OTHER': 'x'};
    await server.authenticate('ag1', 'gemini-api-key');
    expect(spawned.single.environment, {'GEMINI_API_KEY': 'k-123'});
    expect(agents.single.authenticatedWith, 'gemini-api-key');
  });

  test('a connection that cannot start keeps the key out of its words, '
      'though the failure names the command line it is on', () async {
    vault = {'GEMINI_API_KEY': 'k-123'};
    nextAgent = () => throw const ProcessException('wsl.exe', [
      '--',
      'env',
      'GEMINI_API_KEY=k-123',
      '/home/me/agy_acp_server.par',
    ], 'The system cannot find the file specified.');
    await expectLater(
      auth().authenticate('ag1', 'gemini-api-key'),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.message, 'message', contains('did not answer'))
            .having((r) => r.message, 'message', isNot(contains('k-123'))),
      ),
    );
  });

  test('a terminal method is refused authenticate, and an unknown one names '
      'what the agent offers', () async {
    await expectLater(
      auth().authenticate('ag1', 'login'),
      throwsA(isA<DataRefused>()),
    );
    expect(agents.single.receivedMethods, ['initialize']);
    await expectLater(
      auth().authenticate('ag1', 'nope'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          contains('oauth-personal'),
        ),
      ),
    );
  });

  test('a terminal login whose terminal does not open is refused, and '
      'remembers nothing', () async {
    final server = ServerAcpAuth(
      installations: () => [antigravity],
      environments: () => [wsl],
      registry: () => AgentRegistry.builtIn,
      choices: AcpAuthChoiceDao(database),
      spawn: (_, _) async => FakeAcpProcess(nextAgent()).spawn(),
      vault: () => vault,
      openTerminal: (_) => null,
      now: () => t0,
      readTimeout: const Duration(seconds: 5),
    );
    await expectLater(
      server.terminalLogin('ag1', 'login'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.unavailable,
        ),
      ),
    );
    expect(server.state('ag1'), isNull);
  });

  test('a terminal login opens a terminal on the machine running what the '
      'method names, remembered unconfirmed', () async {
    final server = auth();
    final typed = await server.terminalLogin('ag1', 'login');
    expect(typed.confirmed, isFalse);
    final appended = terminals.single;
    expect(appended.environment.id, wsl.id);
    expect(appended.agentId, 'antigravity-acp');
    expect(appended.executable, '/home/me/agy_acp_server.par');
    expect(appended.arguments, ['--uid=', 'login']);
    expect(appended.title, contains('Log in'));

    await server.terminalLogin('ag1', 'cli-login');
    expect(terminals.last.executable, 'copilot');
    expect(terminals.last.arguments, ['login']);
    expect(server.state('ag1')!.methodId, 'cli-login');
    expect(server.state('ag1')!.confirmed, isFalse);

    await expectLater(
      server.terminalLogin('ag1', 'oauth-personal'),
      throwsA(isA<DataRefused>()),
    );
  });

  test('forget clears the choice; with logout an agent that offers it is '
      'asked, and one that does not is not', () async {
    final server = auth();
    await server.authenticate('ag1', 'oauth-personal');
    await server.clear('ag1', logout: true);
    expect(agents.last.logouts, 1);
    expect(server.state('ag1'), isNull);

    nextAgent = () => FakeAcpAgent(authMethods: methods);
    await server.authenticate('ag1', 'oauth-personal');
    await server.clear('ag1', logout: true);
    expect(agents.last.receivedMethods, ['initialize']);
    expect(server.state('ag1'), isNull);

    final before = spawned.length;
    await server.clear('ag1');
    expect(spawned.length, before, reason: 'a plain forget starts nothing');
  });

  test('a start takes the remembered method and its key; nothing remembered '
      'leaves the spec as it is', () async {
    final server = auth();
    final spec = AgentRegistry.builtIn.adapterFor('antigravity-acp')!.acp!;
    final none = server.startAuth(antigravity, spec);
    expect(none.spec.authMethodId, isNull);
    expect(none.variables, isEmpty);

    vault = {'GEMINI_API_KEY': 'k-123'};
    await server.authenticate('ag1', 'gemini-api-key');
    final chosen = server.startAuth(antigravity, spec);
    expect(chosen.spec.authMethodId, 'gemini-api-key');
    expect(chosen.spec.linuxArguments, spec.linuxArguments);
    expect(chosen.variables, {'GEMINI_API_KEY': 'k-123'});

    await server.authenticate('ag1', 'oauth-personal');
    expect(server.startAuth(antigravity, spec).variables, isEmpty);
  });

  group('a login under way', () {
    final grok = AgentInstallation(
      id: 'gk1',
      agentId: 'grok',
      executable: const EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/usr/bin/npx',
      ),
      createdAt: t0,
    );

    test('each method says how it completes, and an agent with a terminal '
        'login of its own offers it beside its methods', () async {
      final read = await auth().methods('ag1');
      final byId = {for (final m in read.methods) m.id: m};
      expect(byId['oauth-personal']!.completes, contains('Google sign-in'));
      expect(byId['login']!.completes, contains('agy_acp_server.par login'));
      expect(byId['cli-login']!.completes, contains('`copilot login`'));
      expect(byId.containsKey(kAcpOwnTerminalLoginId), isFalse);

      nextAgent = () => FakeAcpAgent(
        authMethods: const [AuthMethod(id: 'grok.com', name: 'Grok')],
      );
      final grokRead = await auth(more: [grok]).methods('gk1');
      expect(grokRead.methods.map((m) => (m.id, m.terminal)), [
        ('grok.com', false),
        (kAcpOwnTerminalLoginId, true),
      ]);
      expect(grokRead.methods.first.completes, contains('never prints'));
      expect(grokRead.methods.last.completes, contains('--device-auth'));
    });

    test('the link and device code an agent prints are told as they are '
        'heard, on any machine, while only WSL opens it here', () async {
      agentStderr = [
        'starting',
        'To sign in, open '
            'https://accounts.x.ai/oauth2/device?user_code=AB12-CD34.',
        'Confirm this code in your browser: AB12-CD34',
      ];
      await auth().authenticate('ag-win', 'oauth-personal');
      expect(openedLinks, isEmpty);
      expect(told.map((p) => (p.installationId, p.methodId, p.link, p.code)), [
        (
          'ag-win',
          'oauth-personal',
          'https://accounts.x.ai/oauth2/device?user_code=AB12-CD34',
          'AB12-CD34',
        ),
      ]);
    });

    test('a login that never answers ends at once when cancelled, in '
        'words, remembering nothing', () async {
      final never = Completer<void>();
      nextAgent = () =>
          FakeAcpAgent(authMethods: methods, authenticateGate: never.future);
      final server = auth();
      final login = server.authenticate('ag1', 'oauth-personal');
      await pumpUntil(() => agents.isNotEmpty);
      await pumpUntil(
        () => agents.single.receivedMethods.contains('authenticate'),
      );
      server.cancel('ag1');
      await expectLater(
        login,
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            'The login was cancelled.',
          ),
        ),
      );
      expect(server.state('ag1'), isNull);
      expect(server.cancel('ag1'), isA<DataAck>(), reason: 'nothing to end');
    });

    test('a login answered late is remembered, confirmed', () async {
      final later = Completer<void>();
      nextAgent = () =>
          FakeAcpAgent(authMethods: methods, authenticateGate: later.future);
      final server = auth();
      final login = server.authenticate('ag1', 'oauth-personal');
      await pumpUntil(() => agents.isNotEmpty);
      later.complete();
      final state = await login;
      expect(state.confirmed, isTrue);
      expect(server.state('ag1')!.methodId, 'oauth-personal');
    });

    test('a terminal login answers once its terminal ends: a failing exit is '
        'refused, a clean one re-checked with the agent', () async {
      final server = auth();
      terminalEnds = () async => 1;
      await expectLater(
        server.terminalLogin('ag1', 'login'),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            contains('exit code 1'),
          ),
        ),
      );
      expect(server.state('ag1'), isNull);
      expect(told.single.terminal, contains('Log in'));

      terminalEnds = () async => 0;
      nextAgent = () => FakeAcpAgent(
        authMethods: methods,
        initializeMeta: const {
          'claudeCode': {'loggedIn': false},
        },
      );
      await expectLater(
        server.terminalLogin('ag1', 'login'),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.message,
            'message',
            contains('still says it is not logged in'),
          ),
        ),
      );

      nextAgent = () => FakeAcpAgent(
        authMethods: methods,
        initializeMeta: const {
          'claudeCode': {'loggedIn': true},
        },
      );
      final state = await server.terminalLogin('ag1', 'login');
      expect(state.confirmed, isTrue);
    });

    test('cancel stops waiting on a terminal, which stays open', () async {
      final never = Completer<int?>();
      terminalEnds = () => never.future;
      final server = auth();
      final login = server.terminalLogin('ag1', 'login');
      await pumpUntil(() => terminals.isNotEmpty);
      server.cancel('ag1');
      await expectLater(login, throwsA(isA<DataRefused>()));
      expect(server.state('ag1'), isNull);
    });

    test("an agent's own terminal login runs its login through npx, not its "
        'ACP mode', () async {
      AgentInstallationDao(database).insert(grok);
      final state = await auth(
        more: [grok],
      ).terminalLogin('gk1', kAcpOwnTerminalLoginId);
      final opened = terminals.single;
      expect(opened.executable, '/usr/bin/npx');
      expect(opened.arguments, [
        '-y',
        '@xai-official/grok',
        'login',
        '--device-auth',
      ]);
      expect(opened.title, 'Grok: Sign in with a device code');
      expect(state.methodName, 'Sign in with a device code');
      expect(state.confirmed, isFalse);
      await expectLater(
        auth().terminalLogin('ag1', kAcpOwnTerminalLoginId),
        throwsA(isA<DataRefused>()),
      );
    });
  });

  test("a device code is read from a link's user_code or a line naming a "
      'code; a plain line has none', () {
    expect(
      deviceCodeIn(
        'x',
        link: Uri.parse('https://a.example/device?user_code=WX-YZ'),
      ),
      'WX-YZ',
    );
    expect(deviceCodeIn('Enter the code: ABCD-1234 at the page'), 'ABCD-1234');
    expect(deviceCodeIn('ready in 2026-10-12'), isNull);
  });

  test('what an agent says of its login on initialize', () {
    InitializeResult said(Map<String, Object?>? meta) =>
        InitializeResult(protocolVersion: 1, meta: meta);
    expect(loggedInSaid(said(null)), isNull);
    expect(
      loggedInSaid(
        said({
          'claudeCode': {'loggedIn': true},
        }),
      ),
      isTrue,
    );
    expect(
      loggedInSaid(
        said({
          'codex': {'accountType': null},
        }),
      ),
      isFalse,
    );
    expect(
      loggedInSaid(
        said({
          'codex': {'accountType': 'chatgpt'},
        }),
      ),
      isTrue,
    );
  });
}

Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'never came');
}
