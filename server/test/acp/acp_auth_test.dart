import 'dart:io' show ProcessException;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' show AuthMethod;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/src/acp/acp_auth.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

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

  ServerAcpAuth auth() => ServerAcpAuth(
    installations: () => [antigravity, terminalAgent, antigravityOnWindows],
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
      return true;
    },
    openLink: openedLinks.add,
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
      openTerminal: (_) => false,
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
}
