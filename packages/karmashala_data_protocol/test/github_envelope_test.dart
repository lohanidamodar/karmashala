import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// GitHub access and agents' secret requests: a token goes client → server in
/// `github.token.save` and a secret in `secrets.provide`, and nowhere else.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const GithubAccessRead(),
      const GithubTokenSave('github.com', 'ghp_secret'),
      const GithubTokenClear('github.com'),
      const GithubTokenTest('github.com'),
      const GithubHostChoose('github.com', account: 'me'),
      const GithubHostChoose('ghe.corp.example', off: true),
      const SecretRequestsRead(),
      const SecretProvide('r1', 'whsec_x'),
      const SecretDecline('r1'),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(
        jsonEncode(read.request!.argumentsToJson()),
        jsonEncode(request.argumentsToJson()),
        reason: request.kind,
      );
    }
  });

  test('a request prints its kind, never the token or secret it carries', () {
    expect(
      '${const GithubTokenSave('github.com', 'ghp_secret')}',
      isNot(contains('ghp_secret')),
    );
    expect('${const SecretProvide('r1', 'whsec_x')}', isNot(contains('whsec')));
  });

  test('a status answer round-trips and carries no token', () {
    final status = GithubAccessStatus(
      hosts: const [
        GithubHostAccess(
          host: 'github.com',
          status: 'Using gh as @me',
          source: 'gh',
          login: 'me',
          account: 'me',
          ghAccounts: ['me', 'work'],
          ghActiveAccount: 'me',
        ),
      ],
      savedTokens: [
        GithubSavedToken(
          host: 'github.com',
          savedAt: DateTime.utc(2026, 10, 8),
          login: 'octo',
          checkedAt: DateTime.utc(2026, 10, 8, 1),
        ),
      ],
      ghProblem: 'gh is old',
    );
    final json = DataEnvelope.answer(
      4,
      const GithubAccessRead(),
      DataReply(status, 9),
    );
    expect(jsonEncode(json), isNot(contains('token"')));
    final back = DataEnvelope.readAnswer(
      overTheWire(json),
      const GithubAccessRead(),
    ).value;
    expect(back.hosts.single.ghAccounts, ['me', 'work']);
    expect(back.savedFor('github.com')!.login, 'octo');
    expect(back.ghProblem, 'gh is old');
  });
}
