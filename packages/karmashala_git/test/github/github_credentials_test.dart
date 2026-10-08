import 'package:agent_cli/process.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/github_testing.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

class _FakeGh implements GhLogin {
  _FakeGh(this.tokens);

  /// `host account` → token; `host ` is the active account.
  final Map<String, String> tokens;
  final List<String> asked = [];

  @override
  Future<String?> token(String host, {String? account}) async {
    asked.add('$host ${account ?? ''}');
    return tokens['$host ${account ?? ''}'];
  }

  @override
  Future<GhAccountsReading> accounts() async => const GhAccountsReading([]);
}

void main() {
  group('the order tokens are tried in', () {
    test('a Settings token wins over the environment and gh', () async {
      final gh = _FakeGh({'github.com ': 'from-gh'});
      final credentials = GithubCredentials(
        saved: GithubTokenMap({'github.com': 'from-settings'}),
        environment: const {'GH_TOKEN': 'from-env'},
        gh: gh,
      );
      final token = await credentials.tokenFor('github.com');
      expect(token?.value, 'from-settings');
      expect(token?.source, GithubTokenSource.settings);
      expect(gh.asked, isEmpty);
    });

    test('then GH_TOKEN, then GITHUB_TOKEN, before gh is asked', () async {
      final gh = _FakeGh({'github.com ': 'from-gh'});
      final both = GithubCredentials(
        saved: GithubTokenMap(),
        environment: const {'GH_TOKEN': 'a', 'GITHUB_TOKEN': 'b'},
        gh: gh,
      );
      expect((await both.tokenFor('github.com'))?.variable, 'GH_TOKEN');
      final second = GithubCredentials(
        saved: GithubTokenMap(),
        environment: const {'GITHUB_TOKEN': 'b'},
        gh: gh,
      );
      final token = await second.tokenFor('github.com');
      expect(token?.value, 'b');
      expect(token?.source, GithubTokenSource.environment);
      expect(gh.asked, isEmpty);
    });

    test('then gh, and nothing at all is null', () async {
      final credentials = GithubCredentials(
        saved: GithubTokenMap(),
        gh: _FakeGh({'github.com ': 'from-gh'}),
      );
      final token = await credentials.tokenFor('GitHub.com');
      expect(token?.value, 'from-gh');
      expect(token?.source, GithubTokenSource.gh);
      expect(await credentials.tokenFor('ghe.example.com'), isNull);
      await expectLater(
        credentials.requireTokenFor('ghe.example.com'),
        throwsA(isA<GithubNoAccess>()),
      );
    });

    test('a token never prints itself', () async {
      final token = await GithubCredentials(
        saved: GithubTokenMap({'github.com': 'secret-value'}),
      ).tokenFor('github.com');
      expect('$token', isNot(contains('secret-value')));
      expect(token!.key, isNot(contains('secret-value')));
      expect(token.key, githubTokenKey('github.com', 'secret-value'));
    });
  });

  group('the enterprise token', () {
    const environment = {
      'GH_HOST': 'ghe.corp.example',
      'GH_ENTERPRISE_TOKEN': 'enterprise',
    };

    test('goes to the host GH_HOST names', () async {
      final credentials = GithubCredentials(
        saved: GithubTokenMap(),
        environment: environment,
      );
      final token = await credentials.tokenFor('ghe.corp.example');
      expect(token?.value, 'enterprise');
      expect(token?.variable, 'GH_ENTERPRISE_TOKEN');
    });

    test('goes to no other host, github.com included', () async {
      final credentials = GithubCredentials(
        saved: GithubTokenMap(),
        environment: environment,
      );
      expect(await credentials.tokenFor('github.com'), isNull);
      expect(await credentials.tokenFor('other.corp.example'), isNull);
    });

    test('goes nowhere without GH_HOST', () async {
      final credentials = GithubCredentials(
        saved: GithubTokenMap(),
        environment: const {'GH_ENTERPRISE_TOKEN': 'enterprise'},
      );
      expect(await credentials.tokenFor('ghe.corp.example'), isNull);
    });

    test('GH_TOKEN does not reach an Enterprise Server', () async {
      final credentials = GithubCredentials(
        saved: GithubTokenMap(),
        environment: const {'GH_TOKEN': 'dotcom'},
      );
      expect(await credentials.tokenFor('ghe.corp.example'), isNull);
      expect((await credentials.tokenFor('acme.ghe.com'))?.value, 'dotcom');
    });
  });

  group('the gh cache', () {
    test('is reused while fresh and asked again once it expires', () async {
      var now = DateTime.utc(2026, 10, 8, 12);
      final gh = _FakeGh({'github.com ': 'one'});
      final credentials = GithubCredentials(
        saved: GithubTokenMap(),
        gh: gh,
        now: () => now,
      );
      expect((await credentials.tokenFor('github.com'))?.value, 'one');
      gh.tokens['github.com '] = 'two';
      now = now.add(const Duration(minutes: 2));
      expect((await credentials.tokenFor('github.com'))?.value, 'one');
      expect(gh.asked, hasLength(1));
      now = now.add(kGhTokenFresh);
      expect((await credentials.tokenFor('github.com'))?.value, 'two');
      expect(gh.asked, hasLength(2));
    });

    test('a miss is kept too, and forgetGh drops everything', () async {
      final gh = _FakeGh({});
      final credentials = GithubCredentials(saved: GithubTokenMap(), gh: gh);
      expect(await credentials.tokenFor('github.com'), isNull);
      expect(await credentials.tokenFor('github.com'), isNull);
      expect(gh.asked, hasLength(1));
      gh.tokens['github.com '] = 'now';
      credentials.forgetGh();
      expect((await credentials.tokenFor('github.com'))?.value, 'now');
    });
  });

  group('per-host choices', () {
    test('the chosen account is the one gh is asked for', () async {
      final gh = _FakeGh({
        'github.com ': 'active',
        'github.com work': 'work-token',
      });
      final credentials = GithubCredentials(
        saved: GithubTokenMap(),
        gh: gh,
        choiceOf: (host) => const GithubHostChoice(account: 'work'),
      );
      final token = await credentials.tokenFor('github.com');
      expect(token?.value, 'work-token');
      expect(token?.account, 'work');
      final reading = await credentials.describe('github.com');
      expect(reading.describe, 'Using gh as @work');
    });

    test('a host turned off has no token from any source', () async {
      final credentials = GithubCredentials(
        saved: GithubTokenMap({'github.com': 'saved'}),
        environment: const {'GH_TOKEN': 'env'},
        gh: _FakeGh({'github.com ': 'gh'}),
        choiceOf: (host) => GithubHostChoice(off: host == 'github.com'),
      );
      expect(await credentials.tokenFor('github.com'), isNull);
      await expectLater(
        credentials.requireTokenFor('github.com'),
        throwsA(isA<GithubNoAccess>().having((e) => e.off, 'off', isTrue)),
      );
      expect(
        (await credentials.describe('github.com')).describe,
        contains('turned off'),
      );
    });
  });

  group('the status line', () {
    test('names each source in plain words', () async {
      expect(
        (await GithubCredentials(
          saved: GithubTokenMap({'github.com': 't'}),
        ).describe('github.com', savedLogin: 'octo')).describe,
        'Using your saved token as @octo',
      );
      expect(
        (await GithubCredentials(
              saved: GithubTokenMap(),
              gh: _FakeGh({'github.com ': 'g'}),
            ).describe(
              'github.com',
              ghAccounts: const [
                GhAccount(
                  host: 'github.com',
                  login: 'me',
                  active: true,
                  ok: true,
                ),
              ],
            ))
            .describe,
        'Using gh as @me',
      );
      expect(
        (await GithubCredentials(
          saved: GithubTokenMap(),
        ).describe('github.com')).describe,
        'No GitHub access: paste a token or run gh auth login',
      );
    });
  });

  group('gh as a command', () {
    test('is asked for a token per host and account', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: 'gho_x\n', stderr: ''),
      );
      final gh = GhCommandLogin(() => [runner]);
      expect(await gh.token('github.com', account: 'me'), 'gho_x');
      expect(runner.requests.single.arguments, [
        'auth',
        'token',
        '--hostname',
        'github.com',
        '--user',
        'me',
      ]);
    });

    test('a place without gh is passed over for the next', () async {
      final windows = FakeCommandRunner(
        throwError: CommandException('gh is not installed'),
      );
      final wsl = FakeCommandRunner(
        environmentId: 'wsl:archlinux',
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: 'gho_y', stderr: ''),
      );
      expect(
        await GhCommandLogin(() => [windows, wsl]).token('github.com'),
        'gho_y',
      );
    });

    test('lists accounts and keeps no token from them', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout:
              '{"hosts":{"github.com":[{"state":"success","active":true,'
              '"host":"github.com","login":"me","token":"gho_secret"},'
              '{"state":"success","active":false,"host":"github.com",'
              '"login":"work"}]}}',
          stderr: '',
        ),
      );
      final reading = await GhCommandLogin(() => [runner]).accounts();
      expect(reading.problem, isNull);
      expect(reading.accounts.map((a) => a.login), ['me', 'work']);
      expect(reading.accounts.first.active, isTrue);
    });

    test('an older gh is named as too old, with its version', () async {
      final runner = FakeCommandRunner(
        responder: (request) => request.arguments.first == '--version'
            ? const CommandResult(
                exitCode: 0,
                stdout: 'gh version 2.40.1 (2023-12-13)',
                stderr: '',
              )
            : const CommandResult(
                exitCode: 1,
                stdout: '',
                stderr: 'unknown flag: --json',
              ),
      );
      final reading = await GhCommandLogin(() => [runner]).accounts();
      expect(reading.problem, contains('2.81 or later'));
      expect(reading.problem, contains('2.40.1'));
    });
  });

  test('the API root for each kind of host', () {
    expect('${githubApiBase('github.com')}', 'https://api.github.com/');
    expect('${githubApiBase('acme.ghe.com')}', 'https://api.acme.ghe.com/');
    expect(
      '${githubApiBase('ghe.corp.example')}',
      'https://ghe.corp.example/api/v3/',
    );
    expect(
      '${githubGraphqlEndpoint('github.com')}',
      'https://api.github.com/graphql',
    );
    expect(
      '${githubGraphqlEndpoint('ghe.corp.example')}',
      'https://ghe.corp.example/api/graphql',
    );
  });
}
