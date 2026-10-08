import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/github_testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeGithubServer github;
  late FakeGithubServer elsewhere;

  setUp(() async {
    github = await FakeGithubServer.start();
    elsewhere = await FakeGithubServer.start();
  });

  tearDown(() async {
    await github.close();
    await elsewhere.close();
  });

  GithubClient client({DateTime Function()? now}) => fakeGithubClient(
    github,
    GithubCredentials(saved: GithubTokenMap({'github.com': 'tok'})),
    now: now,
  );

  test('sends the token as a bearer to the API host', () async {
    github.on(
      'GET',
      '/user',
      (_) => const FakeGithubReply(200, body: {'login': 'octo'}),
    );
    final answer = await client().rest('github.com', 'user');
    expect(answer.ok, isTrue);
    expect((answer.body as Map)['login'], 'octo');
    expect(github.requests.single.authorization, 'Bearer tok');
  });

  test('no token rides a redirect to another host', () async {
    elsewhere.on(
      'GET',
      '/blob',
      (_) => const FakeGithubReply(200, body: 'log'),
    );
    github.on(
      'GET',
      '/repos/o/r/actions/jobs/1/logs',
      (_) => FakeGithubReply(
        302,
        headers: {'location': '${elsewhere.base.resolve('blob')}'},
      ),
    );
    final answer = await client().rest(
      'github.com',
      'repos/o/r/actions/jobs/1/logs',
      accept: '*/*',
    );
    expect(answer.text, 'log');
    expect(github.requests.single.authorization, 'Bearer tok');
    expect(elsewhere.requests.single.authorization, isNull);
  });

  test('a redirect on the same host keeps the token', () async {
    github
      ..on(
        'GET',
        '/old',
        (_) => const FakeGithubReply(301, headers: {'location': '/new'}),
      )
      ..on('GET', '/new', (_) => const FakeGithubReply(200, body: {}));
    await client().rest('github.com', 'old');
    expect(github.requests.map((r) => r.authorization), [
      'Bearer tok',
      'Bearer tok',
    ]);
  });

  test('a GET is asked again with its ETag and a 304 is answered from what '
      'was kept', () async {
    var calls = 0;
    github.on('GET', '/repos/o/r/pulls', (request) {
      calls++;
      if (request.headers['if-none-match'] == '"v1"') {
        return const FakeGithubReply(304, headers: {'etag': '"v1"'});
      }
      return const FakeGithubReply(
        200,
        body: [
          {'number': 1},
        ],
        headers: {'etag': '"v1"'},
      );
    });
    final api = client();
    final first = await api.rest('github.com', 'repos/o/r/pulls');
    final second = await api.rest('github.com', 'repos/o/r/pulls');
    expect(calls, 2);
    expect(second.fromCache, isTrue);
    expect(second.status, 200);
    expect(second.body, first.body);
  });

  test('a spent budget is waited out without another call', () async {
    final now = DateTime.utc(2026, 10, 8, 12);
    final reset = now.add(const Duration(minutes: 10));
    github.on(
      'GET',
      '/user',
      (_) => FakeGithubReply(
        403,
        body: const {'message': 'API rate limit exceeded'},
        headers: {
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '${reset.millisecondsSinceEpoch ~/ 1000}',
        },
      ),
    );
    final api = client(now: () => now);
    await expectLater(
      api.rest('github.com', 'user'),
      throwsA(isA<GithubRateLimited>()),
    );
    await expectLater(
      api.rest('github.com', 'user'),
      throwsA(isA<GithubRateLimited>().having((e) => e.until, 'until', reset)),
    );
    expect(github.requests, hasLength(1));
  });

  test('GraphQL errors with no data throw; partial data is returned', () async {
    github.onGraphql({
      'broken': (_) => const FakeGithubReply(
        200,
        body: {
          'errors': [
            {'message': 'nope'},
          ],
        },
      ),
      'partial': (_) => const FakeGithubReply(
        200,
        body: {
          'data': {'x': 1},
          'errors': [
            {'message': 'some'},
          ],
        },
      ),
    });
    final api = client();
    await expectLater(
      api.graphql('github.com', 'query broken {}'),
      throwsA(isA<GithubApiException>()),
    );
    expect((await api.graphql('github.com', 'query partial {}'))['data'], {
      'x': 1,
    });
  });

  test('no token for the host is refused before anything is sent', () async {
    final api = fakeGithubClient(
      github,
      GithubCredentials(saved: GithubTokenMap()),
    );
    await expectLater(
      api.rest('github.com', 'user'),
      throwsA(isA<GithubNoAccess>()),
    );
    expect(github.requests, isEmpty);
  });
}
