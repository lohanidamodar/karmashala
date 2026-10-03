import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_acp/testing.dart';
import 'package:test/test.dart';

/// How an agent's auth methods read: the typed `terminal` form, the older
/// `_meta.terminal-auth` spelling, and the plain `agent` method — and
/// whether the agent says it answers `logout`.
void main() {
  group('AuthMethod', () {
    test('an agent method is the default and names nothing to run', () {
      final method = AuthMethod.fromJson(const {
        'id': 'oauth-personal',
        'name': 'Log in with Google',
        'description': 'Opens a browser.',
      });
      expect(method.isTerminal, isFalse);
      expect(method.terminalCommand, isNull);
      expect(method.terminalArguments, isEmpty);
      expect(method.toJson(), {
        'id': 'oauth-personal',
        'name': 'Log in with Google',
        'description': 'Opens a browser.',
      });
    });

    test('a typed terminal method carries its args and env', () {
      final method = AuthMethod.fromJson(const {
        'type': 'terminal',
        'id': 'login',
        'name': 'Log in',
        'args': ['login'],
        'env': {'BROWSER': 'none'},
      });
      expect(method.isTerminal, isTrue);
      expect(method.terminalCommand, isNull);
      expect(method.terminalArguments, ['login']);
      expect(method.env, {'BROWSER': 'none'});
      expect(AuthMethod.fromJson(method.toJson()).toJson(), method.toJson());
    });

    test('_meta.terminal-auth names a command to run instead', () {
      final method = AuthMethod.fromJson(const {
        'id': 'copilot-login',
        'name': 'Log in',
        '_meta': {
          'terminal-auth': {
            'command': 'copilot',
            'args': ['login'],
          },
        },
      });
      expect(method.isTerminal, isTrue);
      expect(method.terminalCommand, 'copilot');
      expect(method.terminalArguments, ['login']);
    });
  });

  group('AgentCapabilities', () {
    test('auth.logout as {} says the agent answers logout', () {
      expect(
        AgentCapabilities.fromJson(const {
          'auth': {'logout': <String, Object?>{}},
        }).supportsLogout,
        isTrue,
      );
      expect(
        AgentCapabilities.fromJson(const {'auth': {}}).supportsLogout,
        isFalse,
      );
      expect(AgentCapabilities.fromJson(const {}).supportsLogout, isFalse);
    });
  });

  group('logout over the wire', () {
    test(
      'an agent that advertises it answers, and forgets the login',
      () async {
        final agent = FakeAcpAgent(supportsLogout: true);
        final client = AcpAgentClient(
          agent.clientPeer(),
          handler: const _NoHandler(),
        );
        final init = await client.initialize(
          clientInfo: const ClientInfo(name: 't', version: '0'),
        );
        expect(init.agentCapabilities.supportsLogout, isTrue);
        await client.authenticate('fake-login');
        await client.logout();
        expect(agent.logouts, 1);
        expect(agent.authenticatedWith, isNull);
        await client.close();
        await agent.close();
      },
    );

    test('an agent without it refuses the method', () async {
      final agent = FakeAcpAgent();
      final client = AcpAgentClient(
        agent.clientPeer(),
        handler: const _NoHandler(),
      );
      await client.initialize(
        clientInfo: const ClientInfo(name: 't', version: '0'),
      );
      await expectLater(
        client.logout(),
        throwsA(
          isA<AcpRpcError>().having(
            (e) => e.code,
            'code',
            JsonRpcErrorCodes.methodNotFound,
          ),
        ),
      );
      await client.close();
      await agent.close();
    });
  });
}

/// Nothing here asks the client for anything.
final class _NoHandler extends AcpClientHandler {
  const _NoHandler();

  @override
  Future<PermissionOutcome> requestPermission(
    String sessionId,
    ToolCallUpdate toolCall,
    List<PermissionOption> options,
  ) => throw UnimplementedError();

  @override
  Future<String> readTextFile(
    String sessionId,
    String path, {
    int? line,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<void> writeTextFile(String sessionId, String path, String content) =>
      throw UnimplementedError();
}
