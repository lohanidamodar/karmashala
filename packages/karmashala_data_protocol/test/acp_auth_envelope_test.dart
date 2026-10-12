import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// Logging in to an ACP agent, through the envelope as JSON text: the
/// methods it advertises, the one remembered, and the login-required refusal.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
      DataEnvelope.readAnswer(
        overTheWire(
          DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
        ),
        request,
      );

  test('every auth request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const AcpAuthMethodsRead('a1'),
      const AcpAuthStateRead('a1'),
      const AcpAuthenticate(installationId: 'a1', methodId: 'oauth-personal'),
      const AcpAuthTerminalLogin(installationId: 'a1', methodId: 'login'),
      const AcpAuthClear('a1'),
      const AcpAuthClear('a1', logout: true),
      const AcpAuthCancel('a1'),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request, isA<AgentWorkRequest<Object?>>());
      expect(
        jsonEncode(read.request!.argumentsToJson()),
        jsonEncode(request.argumentsToJson()),
        reason: request.kind,
      );
    }
  });

  test('methods carry the terminal flag and the key variable', () {
    final back = roundTrip(
      const AcpAuthMethodsRead('a1'),
      const AcpAuthMethods(
        installationId: 'a1',
        supportsLogout: true,
        methods: [
          AcpAuthMethod(id: 'oauth-personal', name: 'Log in with Google'),
          AcpAuthMethod(
            id: 'gemini-api-key',
            name: 'Use Gemini API key',
            description: 'Reads GEMINI_API_KEY.',
            apiKeyVariable: 'GEMINI_API_KEY',
          ),
          AcpAuthMethod(
            id: 'login',
            name: 'Log in',
            terminal: true,
            completes: 'Opens a terminal.',
          ),
        ],
      ),
    ).value;
    expect(back.methods[2].completes, 'Opens a terminal.');
    expect(back.methods[0].completes, isNull);
    expect(back.supportsLogout, isTrue);
    expect(back.methods.map((m) => m.id), [
      'oauth-personal',
      'gemini-api-key',
      'login',
    ]);
    expect(back.methods[1].apiKeyVariable, 'GEMINI_API_KEY');
    expect(back.methods[1].description, 'Reads GEMINI_API_KEY.');
    expect(back.methods[2].terminal, isTrue);
    expect(back.methods[0].terminal, isFalse);
  });

  test('a login under way is told with its link, code or terminal', () {
    final batch = DataChanges(5, [
      const AcpLoginProgress(
        installationId: 'a1',
        methodId: 'grok.com',
        link: 'https://accounts.x.ai/oauth2/device?user_code=AB-CD',
        code: 'AB-CD',
      ),
      const AcpLoginProgress(
        installationId: 'a1',
        methodId: 'login',
        terminal: 'Grok: Sign in',
      ),
    ]);
    final read = DataChanges.fromJson(
      overTheWire(batch.toJson()),
    ).changes.cast<AcpLoginProgress>();
    expect(read.map((p) => (p.methodId, p.link, p.code, p.terminal)), [
      (
        'grok.com',
        'https://accounts.x.ai/oauth2/device?user_code=AB-CD',
        'AB-CD',
        null,
      ),
      ('login', null, null, 'Grok: Sign in'),
    ]);
  });

  test('a link whose sign-in returns to a loopback port says so', () {
    expect(
      loginLinkReturnsLocally(
        Uri.parse(
          'https://accounts.google.com/o/oauth2/v2/auth?response_type=code'
          '&redirect_uri=http%3A%2F%2F127.0.0.1%3A45821%2F',
        ),
      ),
      isTrue,
    );
    expect(
      loginLinkReturnsLocally(
        Uri.parse('https://auth.example/x?redirect_uri=http://localhost:1455'),
      ),
      isTrue,
    );
    expect(
      loginLinkReturnsLocally(
        Uri.parse('https://accounts.x.ai/oauth2/device?user_code=AB-CD'),
      ),
      isFalse,
    );
  });

  test('a state says whether the agent confirmed it; none reads as null', () {
    final confirmed = roundTrip(
      const AcpAuthenticate(installationId: 'a1', methodId: 'oauth-personal'),
      AcpAuthState(
        installationId: 'a1',
        methodId: 'oauth-personal',
        methodName: 'Log in with Google',
        chosenAt: t0,
        authenticatedAt: t0,
      ),
    ).value;
    expect(confirmed.confirmed, isTrue);
    expect(confirmed.authenticatedAt, t0);
    expect(confirmed.methodName, 'Log in with Google');

    final terminal = roundTrip(
      const AcpAuthTerminalLogin(installationId: 'a1', methodId: 'login'),
      AcpAuthState(
        installationId: 'a1',
        methodId: 'login',
        methodName: 'Log in',
        chosenAt: t0,
      ),
    ).value;
    expect(terminal.confirmed, isFalse);

    expect(roundTrip(const AcpAuthStateRead('a1'), null).value, isNull);
  });

  test('loginRequired survives the wire', () {
    const refused = DataRefused(
      DataRefusalCode.loginRequired,
      'asks to be logged in first',
    );
    expect(
      DataRefused.fromJson(overTheWire(refused.toJson())).code,
      DataRefusalCode.loginRequired,
    );
  });
}
