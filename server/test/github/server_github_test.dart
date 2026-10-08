import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/github_testing.dart';
import 'package:karmashala_host/src/github/server_github.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Gh implements GhLogin {
  final tokens = <String, String>{};
  List<GhAccount> listed = const [];
  String? problem;

  @override
  Future<String?> token(String host, {String? account}) async =>
      tokens['$host ${account ?? ''}'];

  @override
  Future<GhAccountsReading> accounts() async =>
      GhAccountsReading(listed, problem: problem);
}

/// Settings → Source control → GitHub, on the server: a token saved where
/// only this account can read it, tested against a fake `/user`, and each
/// host's account or off switch — never the real GitHub.
void main() {
  late Directory data;
  late FakeGithubServer github;
  late _Gh gh;

  setUp(() async {
    data = Directory.systemTemp.createTempSync('server-github-');
    github = await FakeGithubServer.start();
    gh = _Gh();
    github.on('GET', '/user', (request) {
      return switch (request.authorization) {
        'Bearer saved-token' => const FakeGithubReply(
          200,
          body: {'login': 'octo'},
        ),
        'Bearer gh-token' => const FakeGithubReply(200, body: {'login': 'me'}),
        _ => const FakeGithubReply(401, body: {'message': 'Bad credentials'}),
      };
    });
  });

  tearDown(() async {
    await github.close();
    data.deleteSync(recursive: true);
  });

  ServerGithub open({Map<String, String> environment = const {}}) =>
      ServerGithub(
        dataDirectory: data.path,
        environment: environment,
        gh: gh,
        clientFor: (credentials) => fakeGithubClient(github, credentials),
      );

  File stored() => File(p.join(data.path, 'secrets', ServerGithub.fileName));

  test('a saved token is used first, kept in the secrets folder, and never '
      'answered back', () async {
    gh.tokens['github.com '] = 'gh-token';
    final server = open(environment: const {'GH_TOKEN': 'env-token'});
    final status =
        await server.handle(const GithubTokenSave('github.com', 'saved-token'))
            as GithubAccessStatus;
    expect(
      (await server.credentials.tokenFor('github.com'))?.value,
      'saved-token',
    );
    final host = status.hosts.firstWhere((h) => h.host == 'github.com');
    expect(host.source, 'settings');
    expect(host.status, 'Using your saved token');
    expect(status.savedFor('github.com'), isNotNull);
    expect('${status.toJson()}', isNot(contains('saved-token')));
    expect(stored().readAsStringSync(), contains('saved-token'));

    // A restart reads it back.
    final again = open();
    expect(again.tokenFor('github.com'), 'saved-token');
  });

  test('Test asks /user as the saved token and keeps who it is', () async {
    final server = open();
    await server.handle(const GithubTokenSave('github.com', 'saved-token'));
    final check =
        await server.handle(const GithubTokenTest('github.com'))
            as GithubTokenCheck;
    expect(check.ok, isTrue);
    expect(check.login, 'octo');
    expect(github.requests.single.authorization, 'Bearer saved-token');
    final status = await server.status();
    expect(status.savedFor('github.com')!.login, 'octo');
    expect(status.savedFor('github.com')!.checkedAt, isNotNull);
    expect(status.hosts.first.status, 'Using your saved token as @octo');
  });

  test('a token GitHub refuses fails its test in words', () async {
    final server = open();
    await server.handle(const GithubTokenSave('github.com', 'wrong'));
    final check = await server.test('github.com');
    expect(check.ok, isFalse);
    expect(check.message, contains('401'));
  });

  test('Clear forgets the token and the next source takes over', () async {
    gh.tokens['github.com '] = 'gh-token';
    gh.listed = const [
      GhAccount(host: 'github.com', login: 'me', active: true, ok: true),
    ];
    final server = open();
    await server.handle(const GithubTokenSave('github.com', 'saved-token'));
    final status =
        await server.handle(const GithubTokenClear('github.com'))
            as GithubAccessStatus;
    expect(status.savedTokens, isEmpty);
    expect(status.hosts.first.status, 'Using gh as @me');
    expect(stored().readAsStringSync(), isNot(contains('saved-token')));
    final check = await server.test('github.com');
    expect(check.login, 'me');
  });

  test('a blank or spaced token is refused, and nothing is written', () async {
    final server = open();
    await expectLater(
      server.handle(const GithubTokenSave('github.com', '  ')),
      throwsA(isA<DataRefused>()),
    );
    await expectLater(
      server.handle(const GithubTokenSave('github.com', 'two words')),
      throwsA(isA<DataRefused>()),
    );
    expect(stored().existsSync(), isFalse);
  });

  test('each host picks its gh account, or is turned off', () async {
    gh
      ..tokens['github.com '] = 'active'
      ..tokens['github.com work'] = 'work-token'
      ..tokens['ghe.corp.example '] = 'ghe-token'
      ..listed = const [
        GhAccount(host: 'github.com', login: 'me', active: true, ok: true),
        GhAccount(host: 'github.com', login: 'work', active: false, ok: true),
        GhAccount(
          host: 'ghe.corp.example',
          login: 'corp',
          active: true,
          ok: true,
        ),
      ];
    final server = open();
    var status =
        await server.handle(
              const GithubHostChoose('github.com', account: 'work'),
            )
            as GithubAccessStatus;
    final dotCom = status.hosts.firstWhere((h) => h.host == 'github.com');
    expect(dotCom.account, 'work');
    expect(dotCom.ghAccounts, ['me', 'work']);
    expect(dotCom.ghActiveAccount, 'me');
    expect(dotCom.status, 'Using gh as @work');
    expect(
      (await server.credentials.tokenFor('github.com'))?.value,
      'work-token',
    );

    status =
        await server.handle(
              const GithubHostChoose('ghe.corp.example', off: true),
            )
            as GithubAccessStatus;
    final corp = status.hosts.firstWhere((h) => h.host == 'ghe.corp.example');
    expect(corp.off, isTrue);
    expect(corp.status, contains('turned off'));
    expect(await server.credentials.tokenFor('ghe.corp.example'), isNull);
    await expectLater(
      server.client.rest('ghe.corp.example', 'user'),
      throwsA(isA<GithubNoAccess>()),
    );

    // Back on, and the choices survive a restart.
    final again = open();
    expect(again.choiceOf('github.com').account, 'work');
    expect(again.choiceOf('ghe.corp.example').off, isTrue);
    await again.handle(const GithubHostChoose('ghe.corp.example'));
    expect(
      (await again.credentials.tokenFor('ghe.corp.example'))?.value,
      'ghe-token',
    );
  });

  test('with nothing anywhere the status says what to do', () async {
    gh.problem = 'gh is not installed on the server\'s machine.';
    final status = await open().status();
    expect(
      status.hosts.single.status,
      'No GitHub access: paste a token or run gh auth login',
    );
    expect(status.ghProblem, contains('not installed'));
  });
}
